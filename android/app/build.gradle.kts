import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key lives in android/key.properties, which is gitignored along
// with the keystore it points at. Absence is not an error: a fresh checkout,
// a CI runner or another developer's machine has no business holding the
// release key, and `flutter build apk --release` still has to work there. So
// the file is read if present and the release build falls back to the debug
// signing config if it is not — with a warning, because a debug-signed
// artefact must never be mistaken for one that can be uploaded to Play.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties =
    Properties().apply {
        if (keystorePropertiesFile.exists()) {
            keystorePropertiesFile.inputStream().use { load(it) }
        }
    }
val hasUploadKey =
    keystorePropertiesFile.exists() &&
        keystoreProperties.getProperty("storeFile") != null &&
        rootProject.file(keystoreProperties.getProperty("storeFile")).exists()

android {
    namespace = "com.dhivalabs.secure_shell_go"
    // Play requires the target API to track the platform; compiling against
    // an older SDK than we target is not a supported combination, so these
    // two move together. See defaultConfig.targetSdk for the floor and why
    // it is a floor rather than a pin.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    // NDK r28+, which emits 16 KB-aligned shared objects by default. Nothing
    // in this project compiles native code — the only .so files in the
    // bundle come prebuilt from the Flutter engine — but the version is
    // pinned through Flutter so a plugin that *does* build native code
    // inherits an alignment-correct toolchain rather than an ad-hoc one.
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dhivalabs.secure_shell_go"
        // flutter_secure_storage 10.x requires API 23 (Android Keystore +
        // EncryptedSharedPreferences). Flutter's own floor is already higher
        // today, so take whichever is greater rather than pinning ourselves
        // below the plugin's minimum if that default ever drops.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        // Play's current bar for new apps and updates is API 35 (Android 15);
        // it rises to API 36 (Android 16) for submissions from 31 Aug 2026.
        // Flutter's default is already 36, so this expression is a floor and
        // not a pin: it tracks Flutter upwards, and stops a Flutter downgrade
        // from silently dropping the app below what Play will accept.
        targetSdk = maxOf(flutter.targetSdkVersion, 36)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasUploadKey) {
                    signingConfigs.getByName("upload")
                } else {
                    logger.warn(
                        "SecureShell Go: android/key.properties not found — " +
                            "signing the release build with the debug key. " +
                            "The output is runnable but CANNOT be uploaded " +
                            "to Google Play.",
                    )
                    signingConfigs.getByName("debug")
                }
            // R8 in full mode plus resource shrinking. Both are off in the
            // Flutter template; turning them on is what strips the unused
            // half of dartssh2's cipher/KEX tables and xterm's unreferenced
            // widgets out of the Java side of the build. Keep rules that the
            // shrinker cannot infer live in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
