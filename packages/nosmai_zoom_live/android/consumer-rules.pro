# Zoom Video SDK: JNI and reflection; its AAR ships no consumer rules.
-keep class us.zoom.** { *; }
-keep class com.zipow.** { *; }
-keep class us.zipow.** { *; }
-keep class org.webrtc.** { *; }
-keep class us.google.protobuf.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keep class androidx.security.crypto.** { *; }
-dontwarn us.zoom.**
-dontwarn com.zipow.**
-dontwarn us.zipow.**
-dontwarn com.google.crypto.tink.**
# Nosmai calls back from native code.
-keep class com.nosmai.** { *; }
-dontwarn com.nosmai.**
-keepclasseswithmembernames class * { native <methods>; }
