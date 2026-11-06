[English](README.md) | [繁體中文](README.zh-TW.md)

# disk-health-check（硬碟健檢）

Windows 用的每月硬碟健檢工具。每月 1 號（當天沒開機則於下次登入時）跳出通知，詢問是否對本機所有硬碟做健康檢查；按「開始掃描」後於背景執行，並產生 HTML 報告。

## 檢查內容

1. **SMART**：用 [CrystalDiskInfo](https://crystalmark.info/zh-tw/software/crystaldiskinfo/) 的 `/CopyExit` 讀取全部硬碟，沿用它的健康判定與你自訂的門檻。
2. **重點屬性與上次比對**：HDD 看重新配置／待重新配置／無法修正磁區與 CRC；NVMe 看嚴重警告、媒體錯誤、已用壽命、備用區塊，報告會標示是否增加。
3. **檔案系統線上掃描**：對每個 NTFS 磁碟區執行 `Repair-Volume -Scan`（唯讀、不鎖碟，可照常使用電腦；作者環境全部約 25 分鐘）。
4. **系統事件記錄**：上次健檢以來 disk／Ntfs／stornvme 等來源的警告與錯誤（壞軌類事件會特別標示）。

## 需求

- Windows，內建 Windows PowerShell 5.1（作者在 Windows 11 開發與使用，其他版本未測試）。
- **需要系統管理員權限**：`install.ps1` 會跳一次 UAC 來註冊排程。掃描由最高權限的排程執行，平常掃描時不會再跳 UAC。
- **CrystalDiskInfo**（本專案不附帶）。請到 <https://crystalmark.info/zh-tw/software/crystaldiskinfo/> 下載免安裝（zip）版（原始碼：<https://github.com/hiyohiyo/CrystalDiskInfo>，MIT 授權）。解壓縮後讓 `DiskInfo64.exe` 位於本工具資料夾旁的 `CrystalDiskInfo` 資料夾內；或放在任何位置，並把使用者環境變數 `DISKHEALTH_CDI_DIR` 設為該資料夾。該資料夾必須可寫入，因為 CrystalDiskInfo 會在裡面產生 `DiskInfo.txt`。程式會依序尋找 `DiskInfo64.exe`、`DiskInfo64S.exe`、`DiskInfo64K.exe`。

## 安裝

1. 把資料夾放在固定位置（排程會指向這個位置），並依上述方式放好 CrystalDiskInfo。
2. 執行 `install.ps1`（右鍵「以 PowerShell 執行」，或 `powershell -ExecutionPolicy Bypass -File install.ps1`），出現 UAC 時按允許。
3. 之後若搬移資料夾或更換 CrystalDiskInfo 位置，請重新執行 `install.ps1`。

## 使用

- 等每月通知，或立即健檢：雙擊 `立即健檢.cmd`，或執行 `Start-ScheduledTask -TaskPath '\硬碟健檢\' -TaskName '執行掃描'`。
- 預覽詢問通知：`.\notify.ps1 -Force`。
- 開啟最新報告：雙擊 `開啟最新報告.cmd`，或在完成通知按「開啟報告」。報告存於 `reports\硬碟健檢_<日期>.html`。
- 通知按鈕：**開始掃描**＝啟動掃描排程；**延後**＝通知安靜地放回通知中心，之後再點開按「開始掃描」。

通知與報告的介面文字為繁體中文。

## 會在系統留下什麼

- `\硬碟健檢\` 底下兩個排程：`每月提醒`（每月 1 號 10:00 ＋ 每次登入延遲 3 分鐘，執行 `notify.ps1`，本月已健檢就不問）、`執行掃描`（以最高權限執行 `health_check.ps1`，上限 6 小時）。
- 只寫入 `HKCU` 的登錄：`diskhealth:` 協定（`HKCU:\Software\Classes\diskhealth`）與通知來源（`HKCU:\Software\Classes\AppUserModelId\DiskHealthCheck.Tool`）。
- 來源名稱為「硬碟健檢」的 Windows 通知。
- 本資料夾內的檔案：`data\`（`state.json`、每次的 `scan_*.json`、CrystalDiskInfo 原始輸出、`health_check.log`）與 `reports\`（HTML 報告）。內容含硬碟序號與健康資料，已列入 `.gitignore`。CrystalDiskInfo 也會在它自己的資料夾產生 `DiskInfo.txt`。
- 掃描為唯讀：只用 `Repair-Volume -Scan`，不會修復、也不會鎖碟。

## 解除安裝

執行 `uninstall.ps1`（會要 UAC）。它會移除兩個排程、`diskhealth:` 協定與通知來源；報告與資料會保留，想清掉請自行刪除資料夾。

## 檔案

| 檔案 | 用途 |
|---|---|
| `install.ps1` / `uninstall.ps1` | 安裝／移除排程、協定、通知來源 |
| `register_user.ps1` | 註冊協定與通知來源（HKCU） |
| `health_check.ps1` | 健檢本體（需管理員） |
| `notify.ps1` | 跳詢問通知；`-Force` 不管本月是否已檢都跳 |
| `handler.ps1` | 通知按鈕處理 |
| `common.ps1` | 共用設定與函式 |
| `launcher.vbs` | 無視窗啟動 PowerShell |

## 授權

[MIT](LICENSE)。CrystalDiskInfo 是另一個獨立專案、有自己的授權，不隨本專案散布。
