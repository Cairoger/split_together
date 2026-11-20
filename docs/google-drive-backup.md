# Android 的 Google Drive 備份與還原

## 換手機如何帶走帳本

1. 在原裝置開啟「設定 → 備份與還原」，點「連結 Google 帳戶」，選擇用來保管帳本的帳戶。平常離線記帳不需要登入。
2. 點「立即備份」，核對目的帳戶與上傳範圍，再點「確認備份」。畫面會顯示該帳戶的上次成功備份時間。備份期間請留在這一頁。
3. 在另一台 Android 裝置開啟**相同版本別**的 SplitTogether，使用同一個 Google 帳戶。帳本須為空，連已封存的群組、已移出常用名單的朋友都算本機資料。只修改過外觀或預設名稱仍可還原。
4. 點「從備份還原」，按上傳時間選擇版本。核對快照時間，以及群組、成員、消費、還款、快速聚餐與朋友的筆數。按「繼續」後還有最後一次確認。完成後，回到首頁核對分帳，並按需重新設定銀行收款資料。

同一帳戶與版本別保留最近兩份成功快照。整理舊檔在新快照上傳成功後才進行。如果上傳後斷線，可能暫時看見多於兩份備份，下次成功備份會再整理。每個版本都是一份完整帳本，可以選擇上一份還原。解除連結或更換帳戶只改變這台裝置使用的連線，既有本機帳目與雲端快照都會保留。

## 上傳範圍

| 資料 | 備份內容 |
| --- | --- |
| 群組與成員 | ID、群組類型、姓名、本人與啟用狀態、朋友連結、建立與更新日期及群組封存狀態 |
| 消費與分攤 | 項目、付款人、金額、分類、備註、原始日期、分帳方式、每人設定值與實際分攤結果 |
| 還款 | 雙方成員 ID、金額、備註、還款及建立日期 |
| 快速聚餐 | 每餐的 ID、時間、付款人、總額、當時的出席者 ID 與姓名，以及每人的實際分攤 |
| 常用朋友 | 穩定 ID、姓名與封存狀態 |

姓名、項目、分類和備註是使用者填寫的文字，會照原文備份。專用收款欄位全部排除，包含銀行代碼、完整帳號、密文和末四碼。裝置金鑰、Google 權杖、預設轉帳 App、外觀與預設名稱也不匯出。還原後保留新手機原有的外觀及裝置設定。

備份是有格式版本及 SHA-256 完整性檢查的 UTF-8 JSON，金額以整數的「分」保存。第一版的單份快照上限為 32 MiB。還原會先驗證內容、ID 關聯及分攤金額，再用一筆 SQLite 交易寫入空帳本。備份使用 Google Drive API v3 的隱藏應用程式資料夾。一般的「我的雲端硬碟」檔案清單不會列出這些快照。[Google Drive 應用程式資料夾說明](https://developers.google.com/workspace/drive/api/guides/appdata)

## 開發者的 Google Cloud 設定

1. 在要用的 Google Cloud 專案，進入「API 和服務 → 程式庫」，啟用 **Google Drive API**。[啟用 Google Workspace API](https://developers.google.com/workspace/guides/enable-apis)
2. 開啟 **Google Auth Platform**。在 **Branding** 設定應用程式名稱與支援信箱，在 **Audience** 選擇對象。使用外部測試模式時，把參與驗收的 Google 帳戶加入 **Test users**。在 **Data Access** 加入唯一需要的 Drive 範圍 `https://www.googleapis.com/auth/drive.appdata`。[設定同意畫面與測試使用者](https://developers.google.com/workspace/guides/configure-oauth-consent)
3. 在 **Clients → Create client → Android** 為每組「實際應用程式 ID ＋ 簽章憑證 SHA-1」建立 OAuth 用戶端。這個流程透過 Android 與 Google Play 服務辨識安裝的 App，不必把 client secret、權杖或簽章金鑰放進專案。[建立 Android OAuth 用戶端](https://developers.google.com/workspace/guides/create-credentials)
4. 核對憑證來源。在專案的 `android` 目錄執行 `.\gradlew.bat :app:signingReport` 可查本機各建置類型。若驗收使用既有 CI 安裝檔，可用 Android SDK Build Tools 的 `apksigner verify --print-certs <APK 路徑>` 查看該檔的憑證 SHA-1。如果使用 Play App Signing 分發，請採 Play Console 顯示的 **App signing key certificate** SHA-1。指紋來自實際的測試或發行簽章，換簽章後要重新配對。[Android 簽章與 SHA-1](https://developers.google.com/android/guides/client-auth)

| 安裝版本 | Android 應用程式 ID | 簽章辨識 |
| --- | --- | --- |
| SplitTogether | `com.example.split_together` | 目前專案的 release 指向 debug 簽章，依實際安裝來源核對 SHA-1。 |
| SplitTogether Preview | `com.example.split_together.preview` | 只有 debug 且啟用 `splitTogetherPreview=true` 才有此後綴。CI 與本機可能使用不同憑證。 |

備份按 Google 帳戶及安裝版本別隔離。即使兩組 Android 用戶端登記在同一個 Cloud 專案，App 的清單仍會依備份檔上的應用程式 ID 篩選。正式版還原正式版的備份，Preview 還原 Preview 的備份。要驗證兩個安裝環境可互相還原，兩邊用戶端也要指向同一個 Google Cloud 專案。

## 雙模擬器驗收

請使用兩台有 Google Play 服務的乾淨 Android 測試模擬器、已授權的測試帳戶及虛構帳本。

1. A、B 安裝相同版本別。A 新增兩筆消費、一筆部分還款、一位常用朋友及一餐含臨時成員的聚餐。記下各筆分攤與未清餘額。
2. A 連結測試帳戶，確認初次連結並未上傳。手動備份，增加一筆消費，再做兩次備份。重新進入備份頁，應有最近兩份可以選擇。斷網再按備份，確認成功時間不變。
3. B 用同一帳戶，選最新版本，核對預覽筆數。先取消確認以檢查空帳本，再次操作並確認還原。核對 A、B 的分攤、還款、未清餘額和聚餐姓名；朋友的銀行收款欄應為空。再次還原應被非空帳本檢查擋下。
4. B 切換至另一個測試帳戶，確認清單與成功時間屬於新帳戶。再切回第一個帳戶，可看見原備份。解除連結後可繼續離線查看 B 的帳本。
5. 在乾淨測試環境以同一帳戶分別開啟正式版和 Preview，給兩邊建立容易區分的虛構資料並各備份一次。兩版各自只應列出自己的快照，任一版的版本整理也不應影響另一版。

無法授權時，依序核對模擬器的 Google Play 服務、網路、測試使用者、Drive API，以及已安裝程式的 ID 和 SHA-1。授權到期可重新連結。備份若未通過格式或完整性檢查，可以改選較早的一份。
