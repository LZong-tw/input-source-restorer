import Cocoa
import Carbon

// Use IsSecureEventInputEnabled() as the primary signal — no keyboard permission needed.
// Every password prompt on macOS activates Secure Input, whether it's:
//   - Touch ID / loginwindow / coreautha / SecurityAgent
//   - 1Password, KeePassXC, Bitwarden password fields
//   - HTML <input type="password"> in any browser
//   - Any app with SetSecureEventInput enabled

var lastNonAbcSourceID: String? = nil
var secureInputWasActive = false
var savedBeforeSecure: String? = nil
var myOwnChange = false

let ABC = "com.apple.keylayout.ABC"

let logPath = NSHomeDirectory() + "/.local/log/input-source-restorer.log"

func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    }
}

func currentSourceID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

@discardableResult
func selectSource(id: String) -> Bool {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return false }
    let count = CFArrayGetCount(list)
    for i in 0..<count {
        let raw = CFArrayGetValueAtIndex(list, i)!
        let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
        let srcID = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        if srcID == id {
            myOwnChange = true
            let status = TISSelectInputSource(src)
            if status != noErr {
                log("WARN: TISSelectInputSource returned \(status)")
                myOwnChange = false
            }
            return status == noErr
        }
    }
    log("WARN: source not found in list: \(id)")
    return false
}

func restoreSource(_ target: String, attempt: Int = 1) {
    guard currentSourceID() == ABC else { return }
    let ok = selectSource(id: target)
    if ok {
        log("restored \(target) (attempt \(attempt))")
    } else if attempt < 3 {
        // Retry with backoff — TIS can be briefly unavailable during session transitions
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempt * 150)) {
            restoreSource(target, attempt: attempt + 1)
        }
    } else {
        log("ERROR: failed to restore \(target) after \(attempt) attempts")
    }
}

// Track input source changes — only remember non-ABC sources
DistributedNotificationCenter.default().addObserver(
    forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil,
    queue: .main
) { _ in
    guard let newID = currentSourceID() else { return }
    if myOwnChange { myOwnChange = false; return }
    if newID != ABC { lastNonAbcSourceID = newID }
}

// Poll Secure Input state — DispatchSourceTimer with leeway lets the OS
// coalesce our wake-up with other background timers, saving battery.
let pollTimer = DispatchSource.makeTimerSource(queue: .main)
pollTimer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100), leeway: .milliseconds(50))
pollTimer.setEventHandler {
    let isSecure = IsSecureEventInputEnabled()

    if isSecure && !secureInputWasActive {
        secureInputWasActive = true
        savedBeforeSecure = lastNonAbcSourceID
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        log("secure input ON [\(app)], target: \(savedBeforeSecure ?? "nil")")
    } else if !isSecure && secureInputWasActive {
        secureInputWasActive = false
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let currentID = currentSourceID() ?? "nil"
        log("secure input OFF [\(app)], current: \(currentID), target: \(savedBeforeSecure ?? "nil")")

        guard let target = savedBeforeSecure, currentID == ABC, target != currentID else { return }
        restoreSource(target)
    }
}
pollTimer.resume()

// Init
FileManager.default.createFile(atPath: logPath, contents: nil)
if let initial = currentSourceID(), initial != ABC {
    lastNonAbcSourceID = initial
}
log("started v7 (retry+status), initial source: \(currentSourceID() ?? "nil"), tracked: \(lastNonAbcSourceID ?? "nil")")

NSApplication.shared.setActivationPolicy(.accessory)
CFRunLoopRun()
