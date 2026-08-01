plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.openhearth.trellis"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // The final name (versionCode >2003 rides pubspec's build number,
        // so the fusion installs cleanly over the original Trellis APK).
        applicationId = "com.openhearth.trellis"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The APK is arm64-only, and the enforcement lives in the
        // RELEASE RECIPE, not here: build with `--split-per-abi` and
        // ship the arm64 artifact (how 1.0.0 shipped). Both gradle-side
        // alternatives were tried and failed, measured not assumed:
        // an `ndk { abiFilters += "arm64-v8a" }` block is overridden by
        // Flutter's own target-platform abiFilters on a plain
        // `flutter build apk` (three ABIs, 305MB), and the SAME block
        // makes `--split-per-abi` refuse to configure at all
        // ("Conflicting configuration ... cannot be present when splits
        // abi filters are set"). The stakes: whisper ships only an
        // arm64 native (committed jniLibs), and flutter_onnxruntime
        // (ADR-0007) bundles per-ABI natives inside its AARs — a fat
        // APK is 4x the size and half-broken on non-arm64 anyway.
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
