# R8 keep rules for the release build.
#
# Deliberately almost empty, and that is the finding rather than an oversight.
# Most of what an SSH client would normally have to protect from a shrinker is
# either not on the Java side of this app at all, or is already covered by a
# rule someone else wrote and ships:
#
#   * dartssh2 and pointycastle are Dart packages. `flutter build` compiles
#     them AOT into libapp.so, which R8 never opens. No -keep rule here could
#     affect them either way, so rules naming those packages would be cargo
#     cult.
#   * Tink — which flutter_secure_storage uses to encrypt saved credentials —
#     ships its own consumer rules inside the AAR, and they are more precise
#     than a hand-written guess: they keep the fields of its *shaded*
#     protobuf messages (com.google.crypto.tink.shaded.protobuf, not
#     com.google.protobuf). A blanket `-keep class com.google.crypto.tink.**`
#     on top of that pinned ~31,800 members for no benefit and was removed.
#     Verified after removal: saved credentials still decrypt from the
#     Keystore and a session still authenticates.
#   * The jni / jni_flutter runtime, androidx.fragment and androidx.window
#     likewise ship their own consumer rules.
#   * MainActivity and SessionForegroundService are named in
#     AndroidManifest.xml, and AGP generates keep rules for manifest-declared
#     components automatically.
#   * The three method channels are wired up programmatically
#     (MethodChannel(...).setMethodCallHandler(...)) rather than discovered by
#     name, so ordinary reachability keeps StorageBridge and everything it
#     calls.
#
# What is left is a belt-and-braces keep on the app's own native surface, and
# the attributes that make a Play Console stack trace readable.

# --- Flutter platform channels ---------------------------------------------
# These three classes are the entire native surface of the app. A future
# refactor that registers a component dynamically, or moves the service out of
# the manifest, would otherwise fail only in release — which is the worst
# place to find out. Three classes is not a measurable cost.
-keep class com.dhivalabs.secure_shell_go.MainActivity { *; }
-keep class com.dhivalabs.secure_shell_go.SessionForegroundService { *; }
-keep class com.dhivalabs.secure_shell_go.StorageBridge { *; }

# --- Crash readability ------------------------------------------------------
# Line numbers survive obfuscation so a Play Console stack trace can be
# deobfuscated against the mapping file the AAB ships to Play in
# BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
