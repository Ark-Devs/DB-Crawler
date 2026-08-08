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

        // 23 rather than Flutter's default: flutter_secure_storage stores the
        // database passwords in EncryptedSharedPreferences, which is where
        // Android's keystore-backed encryption starts.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // The ABIs tool/build-core.sh produces. Listing them keeps a
            // stale .so for an ABI we no longer build out of the APK.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
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

            // The Go core is already stripped by the linker and holds no Dart
            // code, so shrinking is left to the Flutter toolchain.
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}
