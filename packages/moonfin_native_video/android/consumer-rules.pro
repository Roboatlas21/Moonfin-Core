# Keep rules for the bundled dav1d (AV1) decoder. Mirrors the proguard.txt that
# shipped inside lib-decoder-av1-release.aar, which is lost when the decoder is
# consumed as a plain .jar + jniLibs instead of an .aar.

# Do not obfuscate native method names.
-keepclasseswithmembernames class * {
    native <methods>;
}

# Members accessed from native code must stay unobfuscated.
-keep class androidx.media3.decoder.VideoDecoderOutputBuffer {
  *;
}
-keep class androidx.media3.decoder.DecoderInputBuffer {
  *;
}
-keep class androidx.media3.decoder.av1.Dav1dDecoder {
  *;
}

# Android finds this method by name, so keep it from being renamed or removed.
-keep class org.moonfin.nativevideo.InsecureTls$AcceptEveryCertificate {
  public java.util.List checkServerTrusted(java.security.cert.X509Certificate[], java.lang.String, java.lang.String);
}
