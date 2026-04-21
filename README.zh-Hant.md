# input-source-restorer

一個小巧的 macOS LaunchAgent，在 Touch ID 或密碼框靜靜把輸入法切成 ABC 之後，自動切回原本的輸入法。

**其他語言：** [English](README.md) · [台語](README.nan-Hant-TW.md)

**完整除錯紀錄：** [繁體中文](https://lzong.tw/zh-Hant/posts/touch-id-swaps-input-source) · [English](https://lzong.tw/en/posts/touch-id-swaps-input-source) · [台語](https://lzong.tw/nan-Hant-TW/posts/touch-id-swaps-input-source)

## 什麼情況會觸發這個 bug

任何 macOS Secure Input 被啟用的時機。已確認的觸發點：

- Touch ID / 啟用 `pam_tid.so` 的 sudo
- 登入 / 解鎖畫面
- Keychain 存取權限提示
- `SecurityAgent` 權限提升對話方塊
- 1Password、KeePassXC、Bitwarden 等的密碼欄位
- 網頁上的 `<input type="password">`
- Gmail 開加密 PDF 的密碼框
- 任何呼叫 `SetSecureEventInput` 的應用程式

## 原理

- 每 0.25 秒輪詢 `IsSecureEventInputEnabled()`（Carbon API）
- Secure Input 啟動時 → 記住最後一次**非 ABC** 的輸入法
- Secure Input 結束時 → 透過 `TISSelectInputSource` 還原
- **只追蹤非 ABC 的輸入法** — TIS 切換到 ABC 發生在 Secure Input 啟動之前，直接記錄「啟動當下的輸入法」會剛好拿到 ABC。這個實作避開這個污染問題。

不需要輔助功能權限、不用鍵盤事件攔截。Swift 約 100 行。

## 安裝

```bash
git clone https://github.com/LZong-tw/input-source-restorer.git
cd input-source-restorer
./install.sh
```

需要 Xcode Command Line Tools（`xcode-select --install`）。

安裝腳本做的事：
- 編譯 `input-source-restorer.swift` 到 `~/.local/bin/input-source-restorer`
- 寫入 LaunchAgent plist 到 `~/Library/LaunchAgents/`
- 載入 agent（登入時自動啟動、被 kill 會自動重啟）
- Log 位置：`~/.local/log/input-source-restorer.log`

## 驗證

隨便觸發一個密碼框（例如設好 `pam_tid.so` 後在 Terminal 跑 `sudo -v`），然後看 log：

```bash
tail -f ~/.local/log/input-source-restorer.log
```

應該會看到 `secure input ON` → `secure input OFF` → `restored <你的輸入法 ID>`。

## 解除安裝

```bash
./uninstall.sh
```

## 為什麼 macOS 不直接修這個

Apple 切換到 ABC 是有意為之的防呆機制（密碼框只接受 ASCII）。缺少的是「認證完成後切回來」這一步。macOS 沒提供 API 讓使用者阻止這個切換，也沒有「認證完成」的通知。這個工具用 user space 的方式補上缺口。

翻過 Apple Developer Forums、Reddit、Stack Overflow、V2EX、Apple Community — 沒有人把 `loginwindow`/`coreautha`/`SecurityAgent` 和 TIS 強制切換這件事串起來過。相關的討論都只停留在描述症狀，沒找到根本原因。

## 授權

MIT
