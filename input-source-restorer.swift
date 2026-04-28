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
var lastSwitchTime: Date = Date()
var lastSwitchSourceID: String? = nil

let ABC = "com.apple.keylayout.ABC"

let logPath = NSHomeDirectory() + "/.local/log/input-source-restorer.log"

let isoFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return df
}()

func log(_ msg: String) {
    let line = "\(isoFormatter.string(from: Date())) \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    }
}

// Top 5 non-system processes by CPU — useful clue for "mystery" switches.
// Runs `ps -arcwwxo pid,%cpu,comm -r | head -6 | tail -5` async.
func snapshotActiveProcesses(completion: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .background).async {
        let pipe = Pipe()
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "ps -arcwwxo pid,%cpu,comm -r 2>/dev/null | head -6 | tail -5 | awk '{printf \"%s(%s%%) \", $3, $2}'"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { completion(str) }
        } catch {
            DispatchQueue.main.async { completion("err") }
        }
    }
}

func currentSourceID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func contextSnapshot(_ event: String, prevSource: String? = nil) -> String {
    let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    let secure = IsSecureEventInputEnabled() ? "1" : "0"
    let dt = String(format: "%.2f", Date().timeIntervalSince(lastSwitchTime))
    let prev = prevSource.map { ", prev=\($0)" } ?? ""
    return "[\(app)|\(bundleID)] secure=\(secure) Δt=\(dt)s\(prev) | \(event)"
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
                log("WARN TISSelectInputSource status=\(status) for \(id)")
                myOwnChange = false
            }
            return status == noErr
        }
    }
    log("WARN source not found in enabled list: \(id)")
    return false
}

func restoreSource(_ target: String, attempt: Int = 1) {
    guard currentSourceID() == ABC else { return }
    let ok = selectSource(id: target)
    if ok {
        log("RESTORED \(target) attempt=\(attempt)")
    } else if attempt < 3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempt * 150)) {
            restoreSource(target, attempt: attempt + 1)
        }
    } else {
        log("ERROR failed to restore \(target) after \(attempt) attempts")
    }
}

var mysterySwitchGeneration = 0

// Track input source changes
DistributedNotificationCenter.default().addObserver(
    forName: .init("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil,
    queue: .main
) { _ in
    guard let newID = currentSourceID() else { return }
    let prev = lastSwitchSourceID

    if myOwnChange {
        myOwnChange = false
        log("TIS_OWN " + contextSnapshot("→ \(newID)", prevSource: prev))
        lastSwitchTime = Date()
        lastSwitchSourceID = newID
        return
    }

    log("TIS " + contextSnapshot("→ \(newID)", prevSource: prev))
    lastSwitchTime = Date()
    lastSwitchSourceID = newID

    if newID != ABC {
        lastNonAbcSourceID = newID
        return
    }

    // newID == ABC and we didn't do it. Mystery switch path.
    guard !secureInputWasActive else { return }
    mysterySwitchGeneration += 1
    let gen = mysterySwitchGeneration

    snapshotActiveProcesses { processes in
        log("MYSTERY_DETECTED procs=[\(processes)]")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        guard gen == mysterySwitchGeneration else {
            log("MYSTERY_SUPERSEDED gen=\(gen)")
            return
        }
        guard currentSourceID() == ABC else {
            log("MYSTERY_DISMISSED reason=user_reverted current=\(currentSourceID() ?? "nil")")
            return
        }
        guard !IsSecureEventInputEnabled() else {
            log("MYSTERY_DISMISSED reason=secure_input_now_active")
            return
        }
        guard !secureInputWasActive else {
            log("MYSTERY_DISMISSED reason=secure_input_path_handling")
            return
        }
        guard let target = lastNonAbcSourceID, target != ABC else {
            log("MYSTERY_DISMISSED reason=no_target")
            return
        }
        log("MYSTERY_CONFIRMED " + contextSnapshot("restoring \(target)"))
        restoreSource(target)
    }
}

// Poll Secure Input state
let pollTimer = DispatchSource.makeTimerSource(queue: .main)
pollTimer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100), leeway: .milliseconds(50))
pollTimer.setEventHandler {
    let isSecure = IsSecureEventInputEnabled()

    if isSecure && !secureInputWasActive {
        secureInputWasActive = true
        savedBeforeSecure = lastNonAbcSourceID
        snapshotActiveProcesses { processes in
            log("SECURE_ON " + contextSnapshot("target=\(savedBeforeSecure ?? "nil") procs=[\(processes)]"))
        }
    } else if !isSecure && secureInputWasActive {
        secureInputWasActive = false
        let currentID = currentSourceID() ?? "nil"
        log("SECURE_OFF " + contextSnapshot("current=\(currentID) target=\(savedBeforeSecure ?? "nil")"))

        guard let target = savedBeforeSecure, currentID == ABC, target != currentID else { return }
        restoreSource(target)
    }
}
pollTimer.resume()

// Track app activations for context (helpful when correlating mystery switches with app focus changes)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    let name = app.localizedName ?? "unknown"
    let bundleID = app.bundleIdentifier ?? "unknown"
    // Only log app activations that happen close to a TIS event (within 2s)
    let dt = Date().timeIntervalSince(lastSwitchTime)
    if dt < 2.0 {
        log("APP_FOCUS [\(name)|\(bundleID)] Δt=\(String(format: "%.2f", dt))s_after_TIS")
    }
}

// Init
FileManager.default.createFile(atPath: logPath, contents: nil)
if let initial = currentSourceID(), initial != ABC {
    lastNonAbcSourceID = initial
    lastSwitchSourceID = initial
}
log("STARTED v9 (rich logging) initial=\(currentSourceID() ?? "nil") tracked=\(lastNonAbcSourceID ?? "nil")")

NSApplication.shared.setActivationPolicy(.accessory)
CFRunLoopRun()
