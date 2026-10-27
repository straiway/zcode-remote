plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.straiway.zcodeshell"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.straiway.zcodeshell"
        minSdk = 26
        targetSdk = 34
        versionCode = 13
        versionName = "1.0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
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
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    // 链接内含授权令牌，用加密存储保存
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // 扫码连接（自带相机权限申请流程）
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
