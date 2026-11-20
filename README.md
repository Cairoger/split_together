# SplitTogether

SplitTogether 是繁體中文的離線分帳 App。適合由一人替旅伴、室友或聚餐朋友記帳。首次啟動時帳本為空，所有已儲存的群組、消費與還款都保存在裝置的 SQLite 資料庫。

## 開始分帳

1. 在「首頁」點「建立群組」，填入群組名稱與類型。App 會自動加入「我」。其他成員每行填一位，也可以之後到「成員管理」新增。
2. 點「新增消費」，填入名稱、金額、日期及分類。選擇付款人與參與者。代付時可以取消勾選付款人，保留其他參與者。
3. 選擇平均、指定金額、百分比或權重，核對每位成員的預覽後儲存。支援新台幣至小數第 2 位，單筆上限為 NT$99,999,999.99。
4. 開啟「智慧結算」查看建議。實際付款後，點選建議或「記錄還款」，核對雙方與實付金額。部分還款會保留剩餘欠款，全部結清後即可封存群組。
5. 從「消費明細」可編輯或確認刪除消費。還款如需更正，請在「還款紀錄」撤銷錯誤紀錄，再登記正確金額。修改消費時，既有還款會保留。

首頁將「我」在每一組的正餘額加總為應收，負餘額的絕對值加總為應付。每組各自提出還款建議。可從結算頁複製文字清單。在「統計」展開任一群組，或進入群組明細，即可查看分類消費合計。

「設定」中的預設名稱套用於之後建立的群組。既有群組可在「成員管理」重新命名。封存群組可從「群組 → 已封存」查閱或解除封存。清除 App 資料、解除安裝或遺失裝置可能導致帳目遺失，目前沒有雲端同步或匯出功能。

## 在 Windows 執行 Android 版

此專案沿用既有 Flutter App 與 Android、iOS 平台設定。開發環境使用 Flutter 3.50.0 stable、Dart 3.14.0。請在專案根目錄執行以下指令。

```powershell
flutter pub get
flutter devices
flutter run -d <Android裝置ID>
```

從 `flutter devices` 選擇實際 Android 裝置或模擬器。首次取得依賴與建置工具可能需要連線，安裝後的記帳流程可離線操作。

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

建置後的 APK 位於 `build/app/outputs/flutter-apk/app-debug.apk`。iOS 原生建置與裝置驗證需使用 macOS 與 Xcode。Windows 在此專案中用於開發及測試。

## 程式與資料

| 位置 | 用途 |
|---|---|
| `lib/domain.dart` | 資料模型、整數金額解析、四種分攤、餘額及貪婪結算演算法 |
| `lib/data/` | Repository、共用寫入驗證、記憶體與 SQLite 實作、schema 與 migration |
| `lib/state.dart` | 透過 ChangeNotifier 載入帳本、在交易提交後刷新畫面 |
| `lib/app.dart`、`lib/ui.dart`、`lib/screens/` | 繁中 Material 3 介面、帳本操作與設定 |
| `test/unit/`、`test/data/`、`test/widget_test.dart` | 計算、持久化及表單操作測試 |

金額使用整數分，百分比使用基點。百分比與權重分攤採最大餘數法，尾差以成員 ID 穩定排序。結算每次配對剩餘欠款與應收金額最大者，可能有其他轉帳次數更少的解。還款只改變餘額，群組總消費僅計入消費紀錄。

正式入口使用 `sqflite` 儲存資料，`path` 組合平台資料路徑，測試使用 `sqflite_common_ffi` 開啟實際 SQLite 檔案。資料庫版本為 1，啟用外鍵，消費與分攤以同一筆交易寫入。日期以 UTC 儲存，畫面顯示裝置當地日期。

版本驗證結果與平台限制請見 [開發進度](docs/PROGRESS.md)。
