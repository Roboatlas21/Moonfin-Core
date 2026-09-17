package org.moonfin.nativevideo

import okhttp3.OkHttpClient
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * media3 streams through HttpURLConnection, which checks the system trust
 * store that the Dart client is told to skip, so a self signed server browses
 * fine and then fails every playback. Turning this on lets the player reach the
 * same server the rest of the app already talks to.
 *
 * The defaults it replaces are put back as soon as the setting goes off, so
 * nothing here outlives the choice the user made.
 */
object InsecureTls {
    private var allowed = false
    private var originalSocketFactory: SSLSocketFactory? = null
    private var originalHostnameVerifier: HostnameVerifier? = null
    private var insecureSocketFactory: SSLSocketFactory? = null

    @Synchronized
    fun setAllowed(allow: Boolean) {
        if (allow == allowed) return
        allowed = allow
        if (allow) apply() else restore()
    }

    private fun apply() {
        originalSocketFactory = HttpsURLConnection.getDefaultSSLSocketFactory()
        originalHostnameVerifier = HttpsURLConnection.getDefaultHostnameVerifier()

        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(AcceptEveryCertificate), SecureRandom())
        val socketFactory = context.socketFactory
        insecureSocketFactory = socketFactory
        HttpsURLConnection.setDefaultSSLSocketFactory(socketFactory)
        HttpsURLConnection.setDefaultHostnameVerifier { _, _ -> true }
    }

    private fun restore() {
        originalSocketFactory?.let { HttpsURLConnection.setDefaultSSLSocketFactory(it) }
        originalHostnameVerifier?.let { HttpsURLConnection.setDefaultHostnameVerifier(it) }
        originalSocketFactory = null
        originalHostnameVerifier = null
        insecureSocketFactory = null
    }

    // Use the current TLS setting for each request, including retries.
    @Synchronized
    fun okHttpClient(base: OkHttpClient): OkHttpClient {
        val socketFactory = insecureSocketFactory
        if (!allowed || socketFactory == null) return base

        return base.newBuilder()
            .sslSocketFactory(socketFactory, AcceptEveryCertificate)
            .hostnameVerifier { _, _ -> true }
            .build()
    }

    // Android calls the hostname-aware overload through reflection. Keep the
    // class public; consumer-rules.pro preserves the class and method names.
    object AcceptEveryCertificate : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit

        override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit

        @Suppress("unused", "UNUSED_PARAMETER")
        fun checkServerTrusted(
            chain: Array<X509Certificate>,
            authType: String,
            host: String,
        ): List<X509Certificate> = chain.toList()

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
