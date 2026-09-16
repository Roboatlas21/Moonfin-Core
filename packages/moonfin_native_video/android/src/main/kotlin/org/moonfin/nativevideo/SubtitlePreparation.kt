package org.moonfin.nativevideo

import java.io.FileNotFoundException
import java.io.IOException
import java.net.MalformedURLException
import java.net.ProtocolException
import java.net.UnknownServiceException
import java.security.cert.CertificateException
import javax.net.ssl.SSLPeerUnverifiedException

// Keep HTTP status and failure phase independent of Media3 and OkHttp messages.
// Cancellation and selection ownership are checked by the caller before retrying.
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
        // A broken body can recover through a fresh GET. Protocol failures
        // before a successful response (such as redirect loops) stay non-retryable.
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
