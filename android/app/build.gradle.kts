import java.io.FileInputStream
import java.util.Properties
import java.util.Base64
import com.android.build.api.variant.FilterConfiguration.FilterType.*
import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.reader(Charsets.UTF_8).use { reader ->
        localProperties.load(reader)
    }
}

var flutterVersionCode = localProperties.getProperty("flutter.versionCode") ?: "1"
var flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val keystorePropertiesExists = keystorePropertiesFile.exists()
if (keystorePropertiesExists) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val releaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val dartDefines = (project.findProperty("dart-defines") as? String)
    .orEmpty()
    .split(',')
    .mapNotNull { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
    }
    .associate { define ->
        define.substringBefore('=') to define.substringAfter('=', "")
    }

if (releaseBuildRequested) {
    val missingDefines = listOf("SELF_UPDATE_URL", "SELF_UPDATE_ASSET_REGEX")
        .filter { dartDefines[it].isNullOrBlank() }
    if (missingDefines.isNotEmpty()) {
        throw GradleException(
            "Release builds require Dart defines: ${missingDefines.joinToString()}"
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

android {
    namespace = "dev.erdem.emporion"
    @Suppress("DEPRECATION")
    compileSdkVersion("android-37.0")
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.erdem.emporion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutterVersionCode.toInt()
        versionName = flutterVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    flavorDimensions += "default"

    productFlavors {
        create("normal") {
            dimension = "default"
            applicationIdSuffix = ""
        }
        create("fdroid") {
            dimension = "default"
            applicationIdSuffix = ".fdroid"
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        getByName("release") {
            val releaseSigningConfig = signingConfigs.getByName("release")
            val signingValuesPresent = listOf(
                releaseSigningConfig.keyAlias,
                releaseSigningConfig.keyPassword,
                releaseSigningConfig.storePassword,
            ).all { !it.isNullOrBlank() }
            val storeExists = releaseSigningConfig.storeFile?.isFile == true
            if (releaseBuildRequested && (!keystorePropertiesExists || !signingValuesPresent || !storeExists)) {
                throw GradleException(
                    "Release builds require android/key.properties and a readable permanent release keystore"
                )
            }
            signingConfig = releaseSigningConfig
        }
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    sourceSets.getByName("test").resources.srcDir("src/androidTest/assets")
}

val abiCodes = mapOf("x86_64" to 1, "armeabi-v7a" to 2, "arm64-v8a" to 3)

android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}


dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("org.fdroid:index:0.2.0")
    implementation("org.fdroid:core:0.0.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

flutter {
    source = "../.."
}
