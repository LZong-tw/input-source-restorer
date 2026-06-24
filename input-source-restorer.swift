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
var secureInputOwner: AppContext? = nil
var myOwnChange = false
var lastSwitchTime: Date = Date()
var lastSwitchSourceID: String? = nil

let ABC = "com.apple.keylayout.ABC"
let systemAuthBundleIDs: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.SecurityAgent",
    "com.apple.CoreAuthentication.agent",
]

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

struct AppContext: Equatable {
    let name: String
    let bundleID: String
    let pid: pid_t
    let windowTitle: String

    var isSystemAuth: Bool {
        systemAuthBundleIDs.contains(bundleID)
    }

    var short: String {
        let title = windowTitle.isEmpty ? "-" : windowTitle
        return "\(name)|\(bundleID)|pid=\(pid)|win=\(title)"
    }
}

func frontWindowTitle(pid: pid_t) -> String {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return ""
    }

    for window in info {
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        return window[kCGWindowName as String] as? String ?? ""
    }

    return ""
}

func currentAppContext() -> AppContext {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return AppContext(name: "unknown", bundleID: "unknown", pid: -1, windowTitle: "")
    }

    return AppContext(
        name: app.localizedName ?? "unknown",
        bundleID: app.bundleIdentifier ?? "unknown",
        pid: app.processIdentifier,
        windowTitle: frontWindowTitle(pid: app.processIdentifier)
    )
}

func contextSnapshot(_ event: String, prevSource: String? = nil) -> String {
    let app = currentAppContext()
    let secure = IsSecureEventInputEnabled() ? "1" : "0"
    let dt = String(format: "%.2f", Date().timeIntervalSince(lastSwitchTime))
    let prev = prevSource.map { ", prev=\($0)" } ?? ""
    return "[\(app.short)] secure=\(secure) Δt=\(dt)s\(prev) | \(event)"
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

@discardableResult
func restoreSource(_ target: String, attempt: Int = 1, reason: String) -> Bool {
    guard let current = currentSourceID() else {
        log("RESTORE_SKIP reason=\(reason) current=nil target=\(target)")
        return false
    }
    guard current == ABC else {
        log("RESTORE_SKIP reason=\(reason) current=\(current) target=\(target)")
        return false
    }

    let ok = selectSource(id: target)
    if ok {
        log("RESTORED \(target) reason=\(reason) attempt=\(attempt)")
        return true
    } else if attempt < 3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempt * 150)) {
            restoreSource(target, attempt: attempt + 1, reason: reason)
        }
    } else {
        log("ERROR failed to restore \(target) reason=\(reason) after \(attempt) attempts")
    }

    return false
}

func verifyRestoreAfterSecureOff(target: String, delayMs: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
        let current = currentSourceID() ?? "nil"
        guard current == ABC else {
            log("VERIFY_OK reason=secure_off+\(delayMs)ms current=\(current) target=\(target)")
            return
        }

        log("VERIFY_RESTORE reason=secure_off+\(delayMs)ms current=\(current) target=\(target)")
        restoreSource(target, reason: "secure_off_verify_\(delayMs)ms")
    }
}

var mysterySwitchGeneration = 0
var lastRestoreAttempt: Date = .distantPast
var consecutiveRestores = 0
var backoffUntil: Date = .distantPast

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

    // Switched to ABC and we didn't do it. The enforce timer (500ms tick)
    // will catch this within a tick. We just log here so we have forensics.
    if !secureInputWasActive && !IsSecureEventInputEnabled() {
        snapshotActiveProcesses { processes in
            log("MYSTERY_DETECTED procs=[\(processes)]")
        }
    }
}

// Poll Secure Input state
let pollTimer = DispatchSource.makeTimerSource(queue: .main)
pollTimer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100), leeway: .milliseconds(50))
pollTimer.setEventHandler {
    let isSecure = IsSecureEventInputEnabled()

    if isSecure && !secureInputWasActive {
        secureInputWasActive = true
        secureInputOwner = currentAppContext()
        savedBeforeSecure = lastNonAbcSourceID
        snapshotActiveProcesses { processes in
            log("SECURE_ON " + contextSnapshot("target=\(savedBeforeSecure ?? "nil") owner=[\(secureInputOwner?.short ?? "nil")] procs=[\(processes)]"))
        }
    } else if !isSecure && secureInputWasActive {
        secureInputWasActive = false
        let currentID = currentSourceID() ?? "nil"
        let owner = secureInputOwner?.short ?? "nil"
        log("SECURE_OFF " + contextSnapshot("current=\(currentID) target=\(savedBeforeSecure ?? "nil") owner=[\(owner)]"))

        if let target = savedBeforeSecure, currentID == ABC, target != currentID {
            consecutiveRestores = 0
            backoffUntil = .distantPast
            restoreSource(target, reason: "secure_off")
            verifyRestoreAfterSecureOff(target: target, delayMs: 250)
            verifyRestoreAfterSecureOff(target: target, delayMs: 750)
        }
        secureInputOwner = nil
    }
}
pollTimer.resume()

// Enforce loop — replaces the 1.5s mystery deferred check with a continuous
// guarantee. If source is ABC and Secure Input is NOT active, restore.
// Has rate limiting and adaptive backoff to avoid restore-wars with offending apps.
let enforceTimer = DispatchSource.makeTimerSource(queue: .main)
enforceTimer.schedule(deadline: .now() + 0.3, repeating: .milliseconds(300), leeway: .milliseconds(100))
enforceTimer.setEventHandler {
    // Secure Input is global. If the frontmost app/window is still the owner,
    // stay conservative and let the password field use ABC. If focus has moved
    // away from the owner, restore so a background secure field cannot poison
    // normal typing in another window.
    let isSecure = IsSecureEventInputEnabled()
    let app = currentAppContext()
    if app.isSystemAuth {
        consecutiveRestores = 0
        return
    }
    if isSecure || secureInputWasActive {
        guard let owner = secureInputOwner else { return }
        guard !owner.isSystemAuth else { return }
        guard app != owner else { return }
    }

    // Skip if we're in adaptive backoff (an offender keeps undoing our restore)
    let now = Date()
    guard now >= backoffUntil else { return }

    // Skip if source is already non-ABC
    guard currentSourceID() == ABC else {
        consecutiveRestores = 0
        return
    }

    // Need a target
    guard let target = lastNonAbcSourceID, target != ABC else { return }

    // Rate limit: don't restore more than once per 250ms
    if now.timeIntervalSince(lastRestoreAttempt) < 0.25 { return }

    // Adaptive backoff: if 5+ consecutive restores in this run, back off 5s
    if consecutiveRestores >= 5 {
        backoffUntil = now.addingTimeInterval(5)
        log("BACKOFF \(consecutiveRestores) consecutive restores, pausing 5s")
        consecutiveRestores = 0
        return
    }

    lastRestoreAttempt = now
    consecutiveRestores += 1
    let owner = secureInputOwner.map { " owner=[\($0.short)]" } ?? ""
    log("ENFORCE " + contextSnapshot("restoring \(target) (consec=\(consecutiveRestores))\(owner)"))
    restoreSource(target, reason: "enforce")
}
enforceTimer.resume()

// Reset consecutive counter when we see a stable non-ABC state for a while
let resetTimer = DispatchSource.makeTimerSource(queue: .main)
resetTimer.schedule(deadline: .now() + 3, repeating: .seconds(3))
resetTimer.setEventHandler {
    if currentSourceID() != ABC && consecutiveRestores > 0 {
        consecutiveRestores = 0
    }
}
resetTimer.resume()

// Track app activations for context (helpful when correlating mystery switches with app focus changes)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    let context = AppContext(
        name: app.localizedName ?? "unknown",
        bundleID: app.bundleIdentifier ?? "unknown",
        pid: app.processIdentifier,
        windowTitle: frontWindowTitle(pid: app.processIdentifier)
    )
    let dt = Date().timeIntervalSince(lastSwitchTime)
    log("APP_FOCUS [\(context.short)] Δt=\(String(format: "%.2f", dt))s_after_TIS")
}

// Init
FileManager.default.createFile(atPath: logPath, contents: nil)
if let initial = currentSourceID(), initial != ABC {
    lastNonAbcSourceID = initial
    lastSwitchSourceID = initial
}
log("STARTED v12 (system auth guard + secure-off verify) initial=\(currentSourceID() ?? "nil") tracked=\(lastNonAbcSourceID ?? "nil")")

NSApplication.shared.setActivationPolicy(.accessory)
CFRunLoopRun()
