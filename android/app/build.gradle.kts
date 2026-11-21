import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Properties
import javax.naming.ldap.LdapName

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Only CI preview builds pass this opt-in property.
val splitTogetherPreview = providers.gradleProperty("splitTogetherPreview")
    // Flutter 在 Windows 會將環境變數名稱轉成大寫。沿用 CI 的同一個開關。
    .orElse(providers.environmentVariable("ORG_GRADLE_PROJECT_splitTogetherPreview"))
    .orNull == "true"

val releaseProperties = Properties()
val releaseStoreFile = try {
    rootProject.file("key.properties").reader(Charsets.UTF_8).use { releaseProperties.load(it) }
    releaseProperties.getProperty("storeFile")?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
} catch (_: Exception) {
    // 只有正式版需要這份本機設定；debug 與 Preview 仍可正常建置。
    null
}

android {
    namespace = "com.example.split_together"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.split_together"
        manifestPlaceholders["splitTogetherAppLabel"] = "SplitTogether"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseStoreFile
            storePassword = releaseProperties.getProperty("storePassword")
            keyAlias = releaseProperties.getProperty("keyAlias")
            keyPassword = releaseProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        debug {
            if (splitTogetherPreview) {
                applicationIdSuffix = ".preview"
                manifestPlaceholders["splitTogetherAppLabel"] = "SplitTogether Preview"
            }
        }
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

class ReleaseSigningCheck(
    private val store: File?,
    private val properties: Properties,
    private val debugStoreFile: File?,
    private val hasInjectedSigning: Boolean,
) : Action<Task> {
    override fun execute(task: Task) = verify()

    fun verify() {
        if (hasInjectedSigning) {
            throw GradleException("請以 android/key.properties 指定正式簽章，並移除額外的簽章覆寫參數。")
        }
        val storePassword = properties.getProperty("storePassword")
        val alias = properties.getProperty("keyAlias")
        val keyPassword = properties.getProperty("keyPassword")
        if (store == null || !store.isFile || storePassword.isNullOrBlank() ||
            alias.isNullOrBlank() || keyPassword.isNullOrBlank()) {
            throw GradleException("缺少正式簽章。請在本機設定 android/key.properties 的 storeFile、storePassword、keyAlias、keyPassword，並確認金鑰檔存在。")
        }
        val certificate = try {
            val keys = KeyStore.getInstance(store, storePassword.toCharArray())
            if (keys.getKey(alias, keyPassword.toCharArray()) is PrivateKey) {
                keys.getCertificate(alias) as? X509Certificate
            } else null
        } catch (_: Exception) {
            null
        } ?: throw GradleException("無法讀取正式簽章私鑰。請在本機核對金鑰檔、別名及密碼。")

        val isDebugCertificate = LdapName(certificate.subjectX500Principal.name).rdns.any {
            it.type.equals("CN", ignoreCase = true) && it.value.toString().equals("Android Debug", ignoreCase = true)
        }
        if (store.canonicalFile == debugStoreFile?.canonicalFile || isDebugCertificate) {
            throw GradleException("正式版不能使用 Android debug 簽章。請指定專用的正式簽章金鑰。")
        }
    }
}

val signingCheck = ReleaseSigningCheck(
    releaseStoreFile,
    releaseProperties,
    android.signingConfigs.getByName("debug").storeFile,
    providers.gradleProperty("android.injected.signing.store.file").isPresent,
)
// Flutter 直接呼叫 assembleRelease。先核對金鑰，避免沒有正式簽章時啟動其他模組的編譯。
val directReleaseBuild = gradle.startParameter.taskNames.any { requested ->
    val taskName = requested.removePrefix(":").removePrefix("app:")
    taskName == "assembleRelease" || taskName == "bundleRelease"
}
if (directReleaseBuild) signingCheck.verify()

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    // 聚合、IDE 與重用組態快取的建置，都在正式版任務執行時確認實際的金鑰。
    doLast(signingCheck)
}

tasks.matching { it.name == "preReleaseBuild" || it.name == "validateSigningRelease" }.configureEach {
    dependsOn(verifyReleaseSigning)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
