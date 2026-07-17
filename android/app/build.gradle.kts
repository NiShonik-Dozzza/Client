import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Читаем параметры подписи из android/key.properties (файл НЕ в git).
// В CI файл создаётся workflow из GitHub Secrets.
// Локально: скопируйте android/key.properties.example → key.properties и заполните.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.exists()) load(FileInputStream(keyPropertiesFile))
}

android {
    // TODO: Замените на ваш реальный package name.
    // Например: com.yourcompany.panelclient
    namespace = "com.efir.client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            if (keyPropertiesFile.exists()) {
                keyAlias     = keyProperties["keyAlias"]     as String
                keyPassword  = keyProperties["keyPassword"]  as String
                storeFile    = file(keyProperties["storeFile"] as String)  // efir-release.jks
                storePassword = keyProperties["storePassword"] as String
            }
            // Если key.properties нет — Gradle упадёт при release-сборке.
            // В CI файл всегда создаётся workflow'ом.
        }
    }

    defaultConfig {
        // TODO: Замените на ваш реальный Application ID.
        applicationId = "com.efir.client"

        // media_kit требует минимум Android 6.0 (API 23).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Без key.properties release-сборка падает (см. tasks.configureEach ниже):
            // debug-подписанный «релиз» нельзя ни распространять, ни обновить поверх.
            signingConfig = if (keyPropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                null
        }
    }
}

// Fail-fast на этапе задачи (не конфигурации — иначе сломались бы и debug-сборки).
tasks.configureEach {
    if ((name.startsWith("assemble") || name.startsWith("bundle")) &&
        name.contains("Release") && !keyPropertiesFile.exists()
    ) {
        doFirst {
            throw GradleException(
                "android/key.properties не найден: release-сборке нужен release-keystore. " +
                    "Скопируйте android/key.properties.example → key.properties и заполните " +
                    "(в CI файл создаётся из GitHub Secrets)."
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
