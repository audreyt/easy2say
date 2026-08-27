plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.audreyt.v2s.android.spike"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.audreyt.v2s.android.spike"
        minSdk = 34
        targetSdk = 35
        versionCode = 1
        versionName = "0.1-spike"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
