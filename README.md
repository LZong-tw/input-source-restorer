# input-source-restorer

A tiny macOS LaunchAgent that restores your input source after Touch ID / password prompts silently switch it to ABC.

**Other languages:** [繁體中文](README.zh-Hant.md) · [台語](README.nan-Hant-TW.md)

**Full debug story:** [English](https://lzong.tw/en/posts/touch-id-swaps-input-source) · [繁體中文](https://lzong.tw/zh-Hant/posts/touch-id-swaps-input-source) · [台語](https://lzong.tw/nan-Hant-TW/posts/touch-id-swaps-input-source)

## What triggers the bug

Any macOS Secure Input activation. Confirmed triggers:

- Touch ID / sudo with `pam_tid.so`
- Login / unlock screen
- Keychain access prompts
- `SecurityAgent` privilege elevation dialogs
- 1Password, KeePassXC, Bitwarden password fields
- HTML `<input type="password">` in any browser
- Gmail's encrypted PDF viewer
- Any app using `SetSecureEventInput`

## How it works

- Polls `IsSecureEventInputEnabled()` (Carbon API) every 0.25s
- When Secure Input activates → saves the last non-ABC input source
- When Secure Input deactivates → restores it via `TISSelectInputSource`
- **Only tracks non-ABC sources** — TIS switches to ABC *before* Secure Input activates, so naively saving "current source at activation" gets ABC. This implementation avoids that contamination.

No accessibility permission required. No keyboard event tap. ~100 lines of Swift.

## Install

```bash
git clone https://github.com/LZong-tw/input-source-restorer.git
cd input-source-restorer
./install.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`).

The install script:
- Compiles `input-source-restorer.swift` to `~/.local/bin/input-source-restorer`
- Writes a LaunchAgent plist to `~/Library/LaunchAgents/`
- Loads the agent (runs on login, restarts if killed)
- Log: `~/.local/log/input-source-restorer.log`

## Verify

Open any password prompt (e.g. `sudo -v` in Terminal with `pam_tid.so`), then check:

```bash
tail -f ~/.local/log/input-source-restorer.log
```

You should see `secure input ON` → `secure input OFF` → `restored <your-ime-id>`.

## Uninstall

```bash
./uninstall.sh
```

## Why this isn't built into macOS

Apple's behavior is intentional: password fields only accept ASCII, so macOS forces ABC. What's missing is the restore call. No public API exists to prevent the switch or be notified of auth completion. This tool fills the gap entirely in user space.

As far as public forums go (Apple Developer Forums, Reddit, Stack Overflow, V2EX, Apple Community), nobody had connected the dots from `loginwindow`/`coreautha`/`SecurityAgent` to TIS force-switching before. Related issue reports all describe symptoms without naming the mechanism.

## License

MIT
