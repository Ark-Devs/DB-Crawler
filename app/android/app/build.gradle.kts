plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.arkdevs.db_crawler"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.arkdevs.db_crawler"

        // Left as Flutter's own floor, which is currently 24 — comfortably
        // above the 23 that flutter_secure_storage needs for its
        // keystore-backed EncryptedSharedPreferences.
        //
        // Pinning a literal below Flutter's floor is not merely ignored: the
        // tool's MinSdkVersionMigration rewrites the line during `flutter
        // build`, and it writes Groovy (`minSdkVersion flutter.minSdkVersion`)
        // into this Kotlin file, which then fails to compile. Hardcoding 23
        // here cost one red build to discover.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // No `ndk { abiFilters }` here. Gradle refuses to have both that and
        // the splits filters that `flutter build apk --split-per-abi` sets,
        // and the per-ABI split is what the release actually ships. The APK
        // gets exactly the ABIs tool/build-core.sh dropped into jniLibs.
    }

    // The Go core is cross-compiled by tool/build-core.sh and dropped here.
    // It is a prebuilt .so rather than something Gradle builds, so it is
    // picked up as a source set instead of through externalNativeBuild.
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    packaging {
        jniLibs {
            // The Go runtime needs its library on disk to dlopen it.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Debug keys for now so `flutter run --release` works. Replace
            // with a real signing config before shipping anywhere.
            signingConfig = signingConfigs.getByName("debug")

            // Shrinking is left entirely to Flutter's Gradle plugin. Setting
            // isMinifyEnabled = false here looked harmless and was not: the
            // plugin turns resource shrinking on for release, and Gradle
            // refuses that combination outright with "Removing unused
            // resources requires unused code shrinking to be turned on".
        }
    }
}

flutter {
    source = "../.."
}
