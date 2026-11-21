# Android 一般版 APK 的本機簽章

### 先核對舊安裝檔

要讓朋友直接更新並保留帳本，需要同一個應用程式 ID、相容的簽章，以及高於舊安裝檔的實際版本碼。一般版使用 `com.example.split_together`，Preview 使用 `com.example.split_together.preview`。

請保留曾交付的一般版 APK。如果分過架構，收齊各架構的 APK，再用 Android SDK Build Tools 的 `aapt2 dump badging <APK路徑>` 查看每份的 `package` 和 `versionCode`，用 `apksigner verify --verbose --print-certs <APK路徑>` 核對公開憑證的 SHA-256。新版通用 APK 的版本碼須高於這些實際值。只看 Flutter 版本字串，會漏掉分架構的版本碼偏移。

本專案早期曾把 release 建置接到 debug 簽章。若朋友手中的一般版使用 Android Debug 憑證，換成新的正式私鑰後，Android 會拒絕覆蓋安裝。遇到這個情形請保留舊 App 和帳本，先決定資料移轉方式。若舊版已有正式簽章，請沿用其原私鑰。

### 在本機建立並保管第一把正式金鑰

確認是首次發行、沒有要沿用的正式金鑰後，在自己的 PowerShell 視窗執行。以下命令使用本機 Android Studio 的 keytool。它會互動詢問密碼和憑證資料。

```powershell
$keyDir = Join-Path $env:USERPROFILE 'SplitTogetherKeys'
$keyFile = Join-Path $keyDir 'split-together-release.p12'
if (Test-Path -LiteralPath $keyFile) { throw '此位置已有金鑰檔，請先核對是否為原簽章。' }
New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
& 'D:\androidstudio\jbr\bin\keytool.exe' -genkeypair -storetype PKCS12 -keystore $keyFile -alias splittogether -keyalg RSA -keysize 3072 -validity 10000
```

用密碼管理器保管密碼，另外保留加密的離線金鑰備份。後續版本更新需要同一把私鑰。密碼只在自己的電腦輸入，勿貼到聊天、終端命令參數或 Git。

用本機文字編輯器建立 `android/key.properties`（UTF-8），填入以下四個欄位。此檔已被 Git 忽略，內含明文密碼，請僅授權自己的 Windows 帳戶讀取。Windows 的檔案路徑可使用正斜線，勿加引號。以下值為示意。

```properties
storeFile=C:/Users/<你的Windows帳戶>/SplitTogetherKeys/split-together-release.p12
keyAlias=splittogether
storePassword=<只在本機填寫>
keyPassword=<只在本機填寫>
```

上述 keytool 建立的 PKCS12 使用相同密碼，兩個密碼欄位填同一個值。若使用原有 JKS，請填入該金鑰庫與該別名各自的密碼。Java properties 以反斜線為跳脫字元，值中若有反斜線，寫為兩個反斜線。

### 產出與驗證

核對舊 APK 後，在 `pubspec.yaml` 設定版本名稱與建置編號。從專案根目錄依序執行 `flutter analyze`、`flutter test`、`flutter build apk --release`。成功時在 `build/app/outputs/flutter-apk/app-release.apk` 取得通用 APK，再用上面的兩個 Build Tools 命令檢查實際套件 ID、版本名稱、版本碼與憑證。最近一次建置若失敗，先前留下的 APK 不能作為本次產物。

在這台 Windows 電腦建置時，若 Gradle 回報 `Could not close incremental caches`，可在同一個 PowerShell 視窗先執行以下設定，再重跑建置。這個設定僅影響目前的工作階段。已用它單獨編譯通過曾出錯的 `package_info_plus` release 模組。

```powershell
$env:GRADLE_OPTS = "$env:GRADLE_OPTS -Dorg.gradle.project.kotlin.incremental=false"
```

最後在乾淨的測試模擬器安裝一份同正式簽章、較低版本碼的測試 APK，建立虛構帳本和一筆還款，記下餘額。使用指定模擬器的 `adb -s <模擬器序號> install -r <本次正式APK>` 就地更新，再查已安裝版本並核對帳目。這個流程不需要連接使用者手機。

[Android 官方簽章說明](https://developer.android.com/studio/publish/app-signing) · [Flutter 的 Android 發行說明](https://docs.flutter.dev/deployment/android#sign-the-app)
