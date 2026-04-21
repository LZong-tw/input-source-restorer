# input-source-restorer

一个幼幼仔ê macOS LaunchAgent，Touch ID 抑是暗號框靜靜仔共輸入法換做 ABC 了後，會自動共你切轉去原本ê輸入法。

**其他語言：** [English](README.md) · [繁體中文](README.zh-Hant.md)

**完整除錯記錄：** [台語](https://lzong.tw/nan-Hant-TW/posts/touch-id-swaps-input-source) · [繁體中文](https://lzong.tw/zh-Hant/posts/touch-id-swaps-input-source) · [English](https://lzong.tw/en/posts/touch-id-swaps-input-source)

## 啥物情形會觸發這个 bug

任何 macOS Secure Input 啟動ê時機。已經確認ê觸發點：

- Touch ID / 啟用 `pam_tid.so` ê sudo
- 登入 / 解鎖畫面
- Keychain 存取權限提示
- `SecurityAgent` 權限提升對話視窗
- 1Password、KeePassXC、Bitwarden ê暗號輸入框
- 網頁頂懸ê `<input type="password">`
- Gmail 開加密 PDF ê暗號框
- 任何呼叫 `SetSecureEventInput` ê應用程式

## 原理

- 每 0.25 秒輪詢 `IsSecureEventInputEnabled()`（Carbon API）
- Secure Input 啟動ê時 → 記上尾一擺**非 ABC** ê輸入法
- Secure Input 結束ê時 → 透過 `TISSelectInputSource` 還原
- **只追蹤非 ABC ê輸入法** — TIS 切換到 ABC 發生佇 Secure Input 啟動ê前，若直接記錄「啟動當下ê輸入法」會拄拄仔抓著 ABC。這个實作閃開這个污染問題。

毋免輔助功能權限、嘛毋免鍵盤事件攔截。Swift 大約 100 行。

## 安裝

```bash
git clone https://github.com/LZong-tw/input-source-restorer.git
cd input-source-restorer
./install.sh
```

需要 Xcode Command Line Tools（`xcode-select --install`）。

安裝程式做ê代誌：
- 編譯 `input-source-restorer.swift` 去 `~/.local/bin/input-source-restorer`
- 寫 LaunchAgent plist 去 `~/Library/LaunchAgents/`
- 載入 agent（登入ê時自動啟動、被 kill 會自動重啟）
- Log 位置：`~/.local/log/input-source-restorer.log`

## 驗證

隨便觸發一个暗號框（例如設好 `pam_tid.so` 了後佇 Terminal 跑 `sudo -v`），閣看 log：

```bash
tail -f ~/.local/log/input-source-restorer.log
```

應該會看著 `secure input ON` → `secure input OFF` → `restored <你ê輸入法 ID>`。

## 解除安裝

```bash
./uninstall.sh
```

## 為啥 macOS 無直接修理這个問題

Apple 共輸入法切去 ABC 是有意ê防悾機制（暗號框干焦接受 ASCII）。欠ê是「認證完成了後切轉來」這一步。macOS 無提供 API 予使用者阻止這个切換，嘛無「認證完成」ê通知。這个家私用 user space ê方式補這个空缺。

揣過 Apple Developer Forums、Reddit、Stack Overflow、V2EX、Apple Community —— 無人有共 `loginwindow`/`coreautha`/`SecurityAgent` 佮 TIS 強制切換這件代誌連起來過。相關ê討論攏停佇描述症狀，無揣著根本原因。

## 授權

MIT
