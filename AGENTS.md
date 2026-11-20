# SplitTogether 開發規範

## 驗證與提交

1. 每次完成開發後，在專案根目錄執行 `flutter analyze` 與 `flutter test`，確認兩者皆通過。若有錯誤，先修正並重新執行檢查。測試失敗時不得推送。
2. 提交前檢查暫存區檔案清單與差異，確認待提交的內容就是通過驗證的版本。不得提交或上傳密碼、API Key、簽章金鑰或含有這些機密的設定檔。
3. 驗證通過後，自動為本次開發變更建立 Git commit，提交訊息應說明修改目的。

## 推送與回報

1. 確認本機 `main` 包含已驗證的提交後，自動執行 `git push origin main`，同步至 GitHub。禁止強制推送，包括 `git push --force`、`-f` 與 `--force-with-lease`。
2. 推送遭拒時保留遠端歷史，回報原因。若整合遠端變更後再推送，須重新通過上述檢查。
3. 完成後回報修改內容、`flutter analyze` 與 `flutter test` 的實際結果、Commit ID 及推送狀態。若未提交或未推送，說明原因。
