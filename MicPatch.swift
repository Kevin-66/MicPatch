// MicPatch: hides the microphone-in-use pill that macOS shows in the menu bar by drawing a
// patch of the menu bar background over it while something is recording from the mic.
// (The dot after the clock can't be covered: macOS keeps it above every app window.)
//
// Finding the pill: MicPatch keeps an invisible 1-pt status item as an anchor. When the mic
// turns on, macOS inserts the pill next to it and shifts items left by a small inset for the
// dot, so how far the anchor moves says where the pill is.
//
// The background comes from menubar-bg.png, built from a screenshot by calibrate.swift.
//
// Logs to ~/Library/Logs/MicPatch.log. Quit with: pkill -x MicPatch

import AppKit
import CoreAudio

let calibratedSize = NSSize(width: 1710, height: 1107)  // screen menubar-bg.png was taken on
let bandScale: CGFloat = 2          // menubar-bg.png pixels per point
let patchHeight: CGFloat = 33       // the menu bar is 34 pt tall; stay off its bottom edge
let pillLinger: TimeInterval = 4    // keep the pill covered while it fades out
let reanchorInterval: TimeInterval = 30
let dryRun = CommandLine.arguments.contains("--dry-run")   // invisible patch, fake 3 s of mic use

// MARK: - Log

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MicPatch.log")
let stampFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

func log(_ message: String) {
    guard let data = "\(stampFormat.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

func describe(_ r: NSRect?) -> String {
    guard let r else { return "?" }
    return String(format: "x %.1f–%.1f", r.minX, r.maxX)
}

func appName(_ pid: pid_t) -> String {
    if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return "\(name) (\(pid))" }
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, 256) > 0 ? "\(String(cString: buf)) (\(pid))" : "pid \(pid)"
}

// MARK: - Microphone state (Core Audio process objects, macOS 14.2+)

enum Mic {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func processes() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// PIDs of processes currently recording from any input device.
    static func recordingPIDs() -> [pid_t] {
        processes()
            .filter { uint32($0, kAudioProcessPropertyIsRunningInput) != 0 }
            .map { pid_t(bitPattern: uint32($0, kAudioProcessPropertyPID)) }
    }
}

// MARK: - Patch window

final class PatchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class Patch {
    private let panel = PatchPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let layer = CALayer()
    private var key = ""

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = dryRun ? 0 : 1
        layer.contentsGravity = .resize
        layer.contentsScale = bandScale
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        panel.contentView = view
    }

    var frame: NSRect? { panel.isVisible ? panel.frame : nil }

    func show(_ rect: NSRect, key newKey: String, image: () -> CGImage?) {
        let k = "\(newKey) \(rect)"
        if k != key {
            guard let img = image() else { return }
            key = k
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(rect, display: false)
            layer.contents = img
            CATransaction.commit()
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

/// Feather widths in points for a patch's left, right and bottom edges.
struct Feather {
    let left: CGFloat, right: CGFloat, bottom: CGFloat
}

func smoothRamp(_ t: CGFloat) -> CGFloat {
    let u = max(0, min(1, t))
    return u * u * (3 - 2 * u)
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate {
    private var band: CGImage!
    private var anchor: NSStatusItem?
    private var anchorCreated = Date.distantPast
    private var idleMinX: CGFloat?        // anchor position with the mic idle (no indicator inset)
    private var learnedInset: CGFloat?    // how far items shift left while the dot is shown
    private var micOn = false
    private var micChanged = Date.distantPast
    private var startedWithMicOn = false
    private var fakeMicUntil: Date?
    private let pill = Patch()
    private var fastTimer: Timer?
    private var watched = Set<AudioObjectID>()
    private var barVisible = true
    private var ticks = 0
    private var loggedActivation = false

    private var screen: NSScreen? { NSScreen.screens.first { $0.frame.size == calibratedSize } }

    /// Frame of the invisible anchor item, once macOS has placed it on the calibrated screen.
    private var anchorFrame: NSRect? {
        guard let f = anchor?.button?.window?.frame, let s = screen,
              f.minX > s.frame.minX + s.frame.width * 0.3, f.maxX <= s.frame.maxX else { return nil }
        return f
    }

    /// How far the anchor has moved left since the mic was idle.
    private var shift: CGFloat? {
        guard let base = idleMinX, let f = anchorFrame else { return nil }
        return base - f.minX
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let url = Bundle.main.url(forResource: "menubar-bg", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            log("menubar-bg.png missing; quitting")
            NSApp.terminate(nil)
            return
        }
        band = image
        log("started (pid \(getpid()))\(dryRun ? " dry run" : "")")
        if screen == nil { log("no \(Int(calibratedSize.width))x\(Int(calibratedSize.height)) screen; patch stays off") }
        makeAnchor()
        watchAudio()
        micOn = !Mic.recordingPIDs().isEmpty
        startedWithMicOn = micOn
        micChanged = Date()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.slowTick() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.idleMinX = nil
            self?.makeAnchor()
        }
        if dryRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.fakeMicUntil = Date().addingTimeInterval(3)
                self?.evaluate()
            }
        }
        evaluate()
    }

    private func makeAnchor() {
        if let old = anchor { NSStatusBar.system.removeStatusItem(old) }
        anchor = NSStatusBar.system.statusItem(withLength: 1)
        anchorCreated = Date()
    }

    private func watchAudio() {
        var list = Mic.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(Mic.system, &list, .main) { [weak self] _, _ in
            self?.watchProcesses()
            self?.evaluate()
        }
        watchProcesses()
    }

    private func watchProcesses() {
        let current = Set(Mic.processes())
        watched.formIntersection(current)
        for process in current.subtracting(watched) {
            var a = Mic.address(kAudioProcessPropertyIsRunningInput)
            let status = AudioObjectAddPropertyListenerBlock(process, &a, .main) { [weak self] _, _ in self?.evaluate() }
            if status == noErr { watched.insert(process) }
        }
    }

    private func slowTick() {
        evaluate()
        guard !micOn, fastTimer == nil, Date().timeIntervalSince(micChanged) > 3 else { return }
        // Mic idle: re-create the anchor now and then so it stays the leftmost item,
        // and remember where it sits without the indicator inset.
        if Date().timeIntervalSince(anchorCreated) > reanchorInterval {
            makeAnchor()
        } else if Date().timeIntervalSince(anchorCreated) > 1.5, let f = anchorFrame {
            idleMinX = f.minX
        }
    }

    private func evaluate() {
        var pids = Mic.recordingPIDs()
        if let until = fakeMicUntil {
            if Date() < until { pids.append(getpid()) } else { fakeMicUntil = nil }
        }
        let on = !pids.isEmpty
        if on != micOn {
            micOn = on
            micChanged = Date()
            loggedActivation = false
            if on {
                log("mic on: \(pids.map(appName).joined(separator: ", ")); anchor \(describe(anchorFrame)), idle x \(idleMinX.map { String(format: "%.1f", $0) } ?? "unknown")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logState() }
            } else {
                log("mic off")
                startedWithMicOn = false
            }
        }
        let active = micOn || Date().timeIntervalSince(micChanged) < pillLinger
        if active, fastTimer == nil {
            fastTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.fastTick() }
        }
        if active { update() }
    }

    private func fastTick() {
        ticks += 1
        if ticks % 4 == 1 { barVisible = menuBarVisible() }
        if fakeMicUntil != nil, Date() >= fakeMicUntil! { evaluate(); return }
        if !micOn, Date().timeIntervalSince(micChanged) >= pillLinger {
            fastTimer?.invalidate()
            fastTimer = nil
            pill.hide()
            if dryRun { log("dry run done"); NSApp.terminate(nil) }
            return
        }
        update()
    }

    private func update() {
        guard let s = screen else { pill.hide(); return }
        let top = s.frame.maxY
        let sh = shift
        let sinceChange = Date().timeIntervalSince(micChanged)

        var pillCase = "hidden"
        if barVisible, micOn || sinceChange < pillLinger, let f = anchorFrame {
            let r: NSRect
            let feather: Feather
            if let sh, sh >= 30 {
                // The pill landed right of the anchor: the anchor moved by inset + pill width.
                pillCase = "right of anchor"
                r = NSRect(x: f.maxX, y: top - patchHeight, width: max(sh - (learnedInset ?? 15), 20), height: patchHeight)
                feather = Feather(left: 3, right: 3, bottom: 3)
            } else if startedWithMicOn, idleMinX == nil {
                // The pill was already up when MicPatch started, so the anchor went left of it.
                pillCase = "right of anchor (guess)"
                r = NSRect(x: f.maxX, y: top - patchHeight, width: 46, height: patchHeight)
                feather = Feather(left: 3, right: 3, bottom: 3)
            } else {
                pillCase = "left of anchor"
                r = NSRect(x: f.minX - 70, y: top - patchHeight, width: 79, height: patchHeight)
                feather = Feather(left: 8, right: 5, bottom: 3)
            }
            pill.show(r, key: pillCase) { makeImage(r, on: s, feather: feather) }
        } else {
            pill.hide()
        }

        if micOn, let sh, sh > 5, sh < 30 { learnedInset = sh }
        if micOn, !loggedActivation, sinceChange > 0.5 {
            loggedActivation = true
            log("patch: pill \(pillCase) \(describe(pill.frame)), shift \(sh.map { String(format: "%.1f", $0) } ?? "?"), menu bar \(barVisible ? "visible" : "hidden")")
        }
    }

    /// Crop of the clean menu bar background for `rect`, with feathered edges.
    private func makeImage(_ rect: NSRect, on s: NSScreen, feather: Feather) -> CGImage? {
        let w = Int((rect.width * bandScale).rounded()), h = Int((rect.height * bandScale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // menubar-bg.png: x from the screen's left edge, y down from its top edge
        let crop = CGRect(x: (rect.minX - s.frame.minX) * bandScale, y: (s.frame.maxY - rect.maxY) * bandScale,
                          width: CGFloat(w), height: CGFloat(h))
        guard let piece = band.cropping(to: crop) else { return nil }
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for y in 0..<h {                     // memory row 0 is the top of the image
            for x in 0..<w {
                let fx = (CGFloat(x) + 0.5) / bandScale, fy = (CGFloat(y) + 0.5) / bandScale
                let alpha = smoothRamp(fx / feather.left) * smoothRamp((rect.width - fx) / feather.right)
                    * smoothRamp((rect.height - fy) / feather.bottom)
                let i = (y * w + x) * 4
                for c in 0..<4 { px[i + c] = UInt8((CGFloat(px[i + c]) * alpha).rounded()) }
            }
        }
        return ctx.makeImage()
    }

    private func menuBarVisible() -> Bool {
        guard let s = screen, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return true }
        let cgTop = primary.frame.maxY - s.frame.maxY   // window bounds use a top-left origin on the primary screen
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        for w in list where (w[kCGWindowLayer as String] as? Int) == menuLevel {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d) else { continue }
            if abs(b.minY - cgTop) < 1, b.height > 20, b.width >= s.frame.width - 1 { return true }
        }
        return false
    }

    private func logState() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        for w in list {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d),
                  b.minY < 40, b.height < 80 else { continue }
            log("  window \(w[kCGWindowOwnerName as String] ?? "?") layer \(w[kCGWindowLayer as String] ?? "?") \(b)")
        }
        log("  anchor \(describe(anchorFrame)), shift \(shift.map { String(format: "%.1f", $0) } ?? "?")")
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
