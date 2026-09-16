#!/usr/bin/env bash
# Moonfin subtitle retry follow-up, on top of the already-applied patch.
# Branch: fix/android-hls-stall
# Baseline: 8ba098fd07cefd33a415842a531b5313b7c9bd3f
# Usage: bash moonfin-subtitle-retry-followup.sh [path/to/Moonfin-Core]
# Default repository: /workspaces/Moonfin-Core (Codespaces).
#
# Creates exactly TWO new local commits:
# 1. Honor Allow untrusted TLS for subtitle HTTP requests, expose and preserve
#    Android's reflective trust-manager callback, cancel preparation on preview
#    release, and tolerate variations of the truncated-response error message.
# 2. TEMP: distinguish retry classification from whether this request will retry.
#
# Existing commits are retained. No Gradle changes, push, workflow dispatch,
# script-file commit, or automatic reset is performed. Unrelated staged files
# are preserved. Both patches are checked before any source changes or commits.
#
# TLS settings are captured when each request starts. There is still no total
# extraction deadline. Warm-up still discards bytes; Media3 fetches them again.
# This does not add recovery for failures in that second fetch.
#
# Validation: isolated Git application/guard checks, focused Kotlin retry and
# release tests, real OkHttp TLS-policy/reflection and truncated-body checks.
# This is not a full Android APK build or an on-device playback test.
(
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
if [ "$#" -gt 1 ]; then
  fail 'Usage: bash moonfin-subtitle-retry-followup.sh [repository-path]'
fi
repo_dir="${1:-/workspaces/Moonfin-Core}"
cd -- "$repo_dir"
cd -- "$(git rev-parse --show-toplevel)"

expected_branch='fix/android-hls-stall'
actual_branch=$(git symbolic-ref --quiet --short HEAD || true)
if [ "$actual_branch" != "$expected_branch" ]; then
  fail "Expected branch $expected_branch. Nothing applied."
fi
expected_head='8ba098fd07cefd33a415842a531b5313b7c9bd3f'
if [ "$(git rev-parse HEAD)" != "$expected_head" ]; then
  fail 'Expected HEAD 8ba098f. Nothing applied; do not reset existing work to bypass this check.'
fi
for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if [ -e "$(git rev-parse --git-path "$state")" ]; then
    fail 'Finish the current Git operation before applying this follow-up. Nothing applied.'
  fi
done

files=(
  'packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt'
  'packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/InsecureTls.kt'
  'packages/moonfin_native_video/android/consumer-rules.pro'
)
diagnostic_files=(
  'packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt'
)
guard_files=("${files[@]}" 'packages/moonfin_native_video/android/build.gradle')
if ! git diff --quiet -- "${guard_files[@]}" ||
   ! git diff --cached --quiet -- "${guard_files[@]}"; then
  fail 'A target file or native build.gradle has tracked changes. Nothing applied.'
fi
git var GIT_AUTHOR_IDENT >/dev/null
git var GIT_COMMITTER_IDENT >/dev/null

patch_dir=$(mktemp -d /tmp/moonfin-subtitle-followup.XXXXXX)
trap 'rm -rf -- "$patch_dir"' EXIT
cat > "$patch_dir/fix.patch" <<'MOONFIN_FOLLOWUP_FIX'
diff --git a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
--- a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
+++ b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
@@ -1987,6 +1987,9 @@
     // path that works around decoder-reuse hangs on some TVs.
     private fun releaseActivePlayer() {
         if (isDisposed) return
+        cancelSubtitlePreparation()
+        clearPendingSubtitle()
+        pendingClosedCaptionId = null
         cancelPendingSubtitleCue(clearView = true)
         cancelPendingAudioRekick()
         closeExternalAudioEffectSessionIfOpen()
@@ -4104,7 +4107,10 @@
         val needsExtraction = url in extractionBackedExternalSubtitleUrls
         if (needsExtraction && warmingExtractionSubtitleUrl != null) return
 
-        val request = SubtitleWarmRequest(subtitleSelectionGeneration, subtitleHttpClient)
+        val request = SubtitleWarmRequest(
+            subtitleSelectionGeneration,
+            InsecureTls.okHttpClient(subtitleHttpClient),
+        )
         warmingExternalSubtitleRequests[url] = request
         if (needsExtraction) warmingExtractionSubtitleUrl = url
         val headers = currentHeaders
@@ -4223,7 +4229,10 @@
                     it is java.net.MalformedURLException ||
                     // OkHttp reports truncated response bodies as protocol errors.
                     (it is java.net.ProtocolException &&
-                        it.message != "unexpected end of stream") ||
+                        it.message?.contains(
+                            "unexpected end of stream",
+                            ignoreCase = true,
+                        ) != true) ||
                     it is java.net.UnknownServiceException ||
                     it is java.security.cert.CertificateException ||
                     it is javax.net.ssl.SSLPeerUnverifiedException ||
diff --git a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/InsecureTls.kt b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/InsecureTls.kt
--- a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/InsecureTls.kt
+++ b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/InsecureTls.kt
@@ -1,5 +1,6 @@
 package org.moonfin.nativevideo
 
+import okhttp3.OkHttpClient
 import java.security.SecureRandom
 import java.security.cert.X509Certificate
 import javax.net.ssl.HostnameVerifier
@@ -22,6 +23,7 @@
     private var allowed = false
     private var originalSocketFactory: SSLSocketFactory? = null
     private var originalHostnameVerifier: HostnameVerifier? = null
+    private var insecureSocketFactory: SSLSocketFactory? = null
 
     @Synchronized
     fun setAllowed(allow: Boolean) {
@@ -36,7 +38,9 @@
 
         val context = SSLContext.getInstance("TLS")
         context.init(null, arrayOf<TrustManager>(AcceptEveryCertificate), SecureRandom())
-        HttpsURLConnection.setDefaultSSLSocketFactory(context.socketFactory)
+        val socketFactory = context.socketFactory
+        insecureSocketFactory = socketFactory
+        HttpsURLConnection.setDefaultSSLSocketFactory(socketFactory)
         HttpsURLConnection.setDefaultHostnameVerifier { _, _ -> true }
     }
 
@@ -45,13 +49,35 @@
         originalHostnameVerifier?.let { HttpsURLConnection.setDefaultHostnameVerifier(it) }
         originalSocketFactory = null
         originalHostnameVerifier = null
+        insecureSocketFactory = null
     }
 
-    private object AcceptEveryCertificate : X509TrustManager {
+    // Snapshot the TLS setting for each new subtitle request.
+    @Synchronized
+    fun okHttpClient(base: OkHttpClient): OkHttpClient {
+        val socketFactory = insecureSocketFactory
+        if (!allowed || socketFactory == null) return base
+
+        return base.newBuilder()
+            .sslSocketFactory(socketFactory, AcceptEveryCertificate)
+            .hostnameVerifier { _, _ -> true }
+            .build()
+    }
+
+    // Android calls the hostname-aware overload through reflection. Keep the
+    // class public; consumer-rules.pro preserves the class and method names.
+    object AcceptEveryCertificate : X509TrustManager {
         override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit
 
         override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) = Unit
 
+        @Suppress("unused", "UNUSED_PARAMETER")
+        fun checkServerTrusted(
+            chain: Array<X509Certificate>,
+            authType: String,
+            host: String,
+        ): List<X509Certificate> = chain.toList()
+
         override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
     }
 }
diff --git a/packages/moonfin_native_video/android/consumer-rules.pro b/packages/moonfin_native_video/android/consumer-rules.pro
--- a/packages/moonfin_native_video/android/consumer-rules.pro
+++ b/packages/moonfin_native_video/android/consumer-rules.pro
@@ -17,3 +17,8 @@
 -keep class androidx.media3.decoder.av1.Dav1dDecoder {
   *;
 }
+
+# Android's X509TrustManagerExtensions calls this overload through reflection.
+-keep class org.moonfin.nativevideo.InsecureTls$AcceptEveryCertificate {
+  public java.util.List checkServerTrusted(java.security.cert.X509Certificate[], java.lang.String, java.lang.String);
+}
MOONFIN_FOLLOWUP_FIX
cat > "$patch_dir/diagnostics.patch" <<'MOONFIN_FOLLOWUP_DIAGNOSTICS'
diff --git a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
--- a/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
+++ b/packages/moonfin_native_video/android/src/main/kotlin/org/moonfin/nativevideo/Media3VideoView.kt
@@ -4132,6 +4132,8 @@
                     .firstOrNull()?.responseCode
                 val stillRequested = !isDisposed && !request.canceled &&
                     request.generation == subtitleSelectionGeneration && pendingExternalSubtitleUrl == url
+                val classifierRetryable = failure?.let { canRetrySubtitle(url, it) } == true
+                val willRetry = classifierRetryable && stillRequested
                 val outcome = if (failure == null) "downloaded" else "failed"
                 subtitleWarmDiagnostic(
                     "attempt=$attempt generation=${request.generation} track=$track $outcome " +
@@ -4139,7 +4141,7 @@
                         "error=${failure?.javaClass?.simpleName} " +
                         "cause=${failure?.cause?.javaClass?.simpleName} " +
                         "canceled=${request.canceled} stillRequested=$stillRequested " +
-                        "retryable=${failure?.let { canRetrySubtitle(url, it) }}",
+                        "classifierRetryable=$classifierRetryable willRetry=$willRetry",
                 )
                 warmingExternalSubtitleRequests.remove(url)
                 if (warmingExtractionSubtitleUrl == url) warmingExtractionSubtitleUrl = null
MOONFIN_FOLLOWUP_DIAGNOSTICS

# A temporary index checks the full patch sequence without touching real staging.
GIT_INDEX_FILE="$patch_dir/index" git read-tree HEAD
GIT_INDEX_FILE="$patch_dir/index" git apply --cached --whitespace=error-all "$patch_dir/fix.patch"
GIT_INDEX_FILE="$patch_dir/index" git apply --cached --check --whitespace=error-all "$patch_dir/diagnostics.patch"
git apply --check --whitespace=error-all "$patch_dir/fix.patch"

git apply --whitespace=error-all "$patch_dir/fix.patch"
git diff --check -- "${files[@]}"
git commit --only -m 'Fix subtitle TLS policy and preview release cancellation' -- "${files[@]}"
fix_commit=$(git rev-parse HEAD)
echo "Functional follow-up committed: $fix_commit"

git apply --check --whitespace=error-all "$patch_dir/diagnostics.patch"
git apply --whitespace=error-all "$patch_dir/diagnostics.patch"
git diff --check -- "${diagnostic_files[@]}"
git commit --only -m 'TEMP: distinguish subtitle retry eligibility from scheduling' -- "${diagnostic_files[@]}"
diagnostic_commit=$(git rev-parse HEAD)
echo "Diagnostic refinement committed: $diagnostic_commit"
echo "To remove only this diagnostic refinement: git revert --no-edit $diagnostic_commit"
echo 'To remove all temporary subtitle diagnostics, including the earlier diagnostic commit:'
echo "git revert --no-edit $diagnostic_commit 8ba098fd07cefd33a415842a531b5313b7c9bd3f"
git --no-pager log -2 --oneline
git status --short
echo 'Two follow-up commits are ready for your manual push and Android workflow run.'
)
