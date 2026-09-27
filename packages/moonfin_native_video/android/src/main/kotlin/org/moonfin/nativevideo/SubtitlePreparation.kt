package org.moonfin.nativevideo

import android.content.Context
import android.net.Uri
import androidx.media3.common.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceInputStream
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.Loader
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.MalformedURLException
import java.net.ProtocolException
import java.net.UnknownServiceException
import java.security.cert.CertificateException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLPeerUnverifiedException

/** Call from the main thread; Loader handles the request, cancellation and retries. */
@UnstableApi
internal class SubtitlePreparation(private val context: Context) {
    private val extractionSlot = Semaphore(1)
    private var active: Read? = null
    private val httpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(120, TimeUnit.SECONDS)
            .readTimeout(600, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    fun prepare(
        uri: Uri,
        headers: Map<String, String>,
        extraction: Boolean,
        onFailure: (IOException) -> Unit,
        onReady: () -> Unit,
    ) {
        if (active != null) return
        val read = Read(uri, headers, extraction, onFailure, onReady)
        active = read
        read.loader.startLoading(read, read, 0)
    }

    fun cancel() {
        val previous = active
        active = null
        previous?.loader?.release()
    }

    private inner class Read(
        val uri: Uri,
        val headers: Map<String, String>,
        val extraction: Boolean,
        val onFailure: (IOException) -> Unit,
        val onReady: () -> Unit,
    ) : Loader.Loadable, Loader.Callback<Read> {
        val loader = Loader("SubtitlePreparation")
        val http = uri.scheme.equals("http", true) || uri.scheme.equals("https", true)
        @Volatile private var canceled = false
        @Volatile private var call: Call? = null

        override fun cancelLoad() {
            canceled = true
            call?.cancel()
        }

        override fun load() {
            // Wait for the canceled extraction request to finish closing.
            // Subtitles that already exist as separate files don't need this wait.
            try {
                if (extraction) extractionSlot.acquire()
            } catch (_: InterruptedException) {
                throw InterruptedIOException()
            }
            try {
                if (canceled) throw InterruptedIOException()
                if (http) {
                    val request = Request.Builder().url(uri.toString())
                    headers.forEach { (name, value) -> request.header(name, value) }
                    request.header("Accept-Encoding", "identity")
                    val nextCall = InsecureTls.okHttpClient(httpClient).newCall(request.build())
                    call = nextCall
                    if (canceled) nextCall.cancel()
                    nextCall.execute().use { response ->
                        if (!response.isSuccessful) throw SubtitleReadFailure(httpStatus = response.code)
                        try {
                            drain(response.body?.byteStream() ?: throw IOException("Missing subtitle response body"))
                        } catch (failure: Exception) {
                            throw SubtitleReadFailure(readingBody = true, cause = failure)
                        }
                    }
                } else {
                    DataSourceInputStream(
                        DefaultDataSource.Factory(context).createDataSource(),
                        DataSpec.Builder().setUri(uri).build(),
                    ).use(::drain)
                }
            } catch (failure: Exception) {
                throw (failure as? SubtitleReadFailure ?: SubtitleReadFailure(cause = failure))
            } finally {
                if (extraction) extractionSlot.release()
            }
        }

        private fun drain(input: InputStream) {
            val buffer = ByteArray(64 * 1024)
            while (!canceled && input.read(buffer) != -1) { /* Media3 reads the file again for playback. */ }
        }

        override fun onLoadCompleted(loadable: Read, elapsedRealtimeMs: Long, loadDurationMs: Long) {
            loader.release()
            if (active !== this || canceled) return
            active = null
            onReady()
        }

        override fun onLoadCanceled(loadable: Read, elapsedRealtimeMs: Long, loadDurationMs: Long, released: Boolean) = Unit

        override fun onLoadError(
            loadable: Read, elapsedRealtimeMs: Long, loadDurationMs: Long, error: IOException, errorCount: Int,
        ): Loader.LoadErrorAction {
            if (active !== this || canceled) return Loader.DONT_RETRY
            if (http && (error as? SubtitleReadFailure)?.isRetryable() == true) {
                val delayMs = (2_000L shl (errorCount - 1).coerceIn(0, 4)).coerceAtMost(30_000L)
                Log.w("SubtitlePreparation", "Subtitle download failed (${subtitleFailureReason(error)}); retrying in ${delayMs}ms")
                return Loader.createRetryAction(false, delayMs)
            }
            active = null
            loader.release()
            onFailure(error)
            return Loader.DONT_RETRY
        }
    }
}

// Report only the HTTP status or exception type, never URLs or request details.
@UnstableApi
internal fun subtitleFailureReason(error: Throwable): String {
    val causes = generateSequence(error) { it.cause }.take(16).toList()
    val status = causes.firstNotNullOfOrNull {
        when (it) {
            is SubtitleReadFailure -> it.httpStatus
            is HttpDataSource.InvalidResponseCodeException -> it.responseCode
            else -> null
        }
    }
    return status?.let { "HTTP $it" } ?: causes.last().javaClass.simpleName
}

// Record the HTTP status and whether the failure happened while reading the file.
// Use these details to decide whether to retry.
internal class SubtitleReadFailure(
    val httpStatus: Int? = null,
    val readingBody: Boolean = false,
    cause: Exception? = null,
) : IOException(cause) {
    fun isRetryable(): Boolean {
        val causes = generateSequence<Throwable>(cause) { it.cause }.take(16).toList()
        if (causes.any {
                it is FileNotFoundException || it is SecurityException ||
                    it is MalformedURLException || it is UnknownServiceException ||
                    it is CertificateException || it is SSLPeerUnverifiedException
            }
        ) return false

        httpStatus?.let { return it == 408 || it == 429 || it in 500..599 }
        // If reading the file fails, try downloading it again. Do not retry
        // protocol errors before a successful response, such as redirect loops.
        if (!readingBody && causes.any { it is ProtocolException }) return false
        return cause is IOException
    }
}

// Media3 can add numbers and colons before a subtitle ID, such as changing
// 100 to 0:100. Allow these prefixes, but reject other changes to the ID.
internal fun matchesExternalSubtitleId(formatId: String?, configurationId: String): Boolean {
    if (formatId == null || configurationId.isEmpty()) return false
    if (formatId == configurationId) return true
    val suffix = ":$configurationId"
    if (!formatId.endsWith(suffix)) return false
    return formatId.removeSuffix(suffix).split(':').all { part ->
        part.isNotEmpty() && part.all { it in '0'..'9' }
    }
}
