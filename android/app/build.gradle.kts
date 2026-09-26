plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cnwhli.bloodsugar_v5"
    // app_links/flutter_blue_plus 等插件要求 compileSdk ≥ 36
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cnwhli.bloodsugar_v5"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // health 插件（Health Connect）要求 minSdk ≥ 26
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 固定签名：keystore 由 CI Secrets 注入（见 build.yml 解码步骤）；
            // 无 keystore 时回退 debug 签名，保证本地/CI 首次构建不断。
            // 注意：debug 签名包与固定签名包互相覆盖安装会报签名不一致，
            // 切换签名只需卸载重装一次，之后固定签名包之间可直接覆盖。
            val ksFile = file(System.getenv("KEYSTORE_PATH") ?: "release.keystore")
            if (ksFile.exists()) {
                signingConfigs.create("fixed") {
                    storeFile = ksFile
                    storePassword = System.getenv("KEYSTORE_PASSWORD")
                    keyAlias = System.getenv("KEY_ALIAS")
                    keyPassword = System.getenv("KEY_PASSWORD")
                }
                signingConfig = signingConfigs.getByName("fixed")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
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
