package org.moonfin.nativevideo

import android.content.Context
import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceInputStream
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
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

    fun prepare(uri: Uri, headers: Map<String, String>, extraction: Boolean, onReady: () -> Unit) {
        if (active != null) return
        val read = Read(uri, headers, extraction, onReady)
        active = read
        read.loader.startLoading(read, read, 0)
    }

    fun cancel() {
        active?.loader?.release()
        active = null
    }

    private inner class Read(
        val uri: Uri,
        val headers: Map<String, String>,
        val extraction: Boolean,
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
            // Wait for any canceled extraction request to close its response first.
            // Known sidecar files don't need to wait.
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
            onReady()
        }

        override fun onLoadCanceled(loadable: Read, elapsedRealtimeMs: Long, loadDurationMs: Long, released: Boolean) = Unit

        override fun onLoadError(
            loadable: Read, elapsedRealtimeMs: Long, loadDurationMs: Long, error: IOException, errorCount: Int,
        ): Loader.LoadErrorAction {
            if (http && (error as? SubtitleReadFailure)?.isRetryable() == true) {
                val delayMs = (2_000L shl (errorCount - 1).coerceIn(0, 4)).coerceAtMost(30_000L)
                return Loader.createRetryAction(false, delayMs)
            }
            loader.release()
            return Loader.DONT_RETRY
        }
    }
}

// Keep the HTTP status and read phase so retries don't depend on error messages.
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
        // Retry a failed body read with a fresh GET, but don't retry protocol
        // errors before a successful response, such as redirect loops.
        if (!readingBody && causes.any { it is ProtocolException }) return false
        return cause is IOException
    }
}

// Media3 may prefix our id with numeric child-source indices when merging.
// Accept only that known form or the original id, never an arbitrary suffix.
internal fun matchesExternalSubtitleId(formatId: String?, configurationId: String): Boolean {
    if (formatId == null || configurationId.isEmpty()) return false
    if (formatId == configurationId) return true
    val suffix = ":$configurationId"
    if (!formatId.endsWith(suffix)) return false
    return formatId.removeSuffix(suffix).split(':').all { part ->
        part.isNotEmpty() && part.all { it in '0'..'9' }
    }
}
