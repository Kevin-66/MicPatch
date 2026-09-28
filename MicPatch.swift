// MicPatch: hides the microphone-in-use pill that macOS shows in the menu bar by drawing a
// patch of the menu bar background over it while something is recording from the mic.
// Input taken from virtual devices (BlackHole, Loopback) doesn't count: macOS shows no pill for it.
// (The dot after the clock can't be covered: macOS keeps it above every app window.)
//
// Finding the pill: MicPatch reads its frame through Accessibility. The pill is the menu bar item
// with identifier com.apple.menuextra.audiovideo ("Audio and Video Controls"), drawn by MenuBarAgent.
// Needs Accessibility permission (System Settings > Privacy & Security > Accessibility); without it
// MicPatch does nothing.
//
// The background comes from menubar-bg.png, built from a screenshot by calibrate.swift.
//
// Logs to ~/Library/Logs/MicPatch.log. Quit with: pkill -x MicPatch
// Run with --register-login or --unregister-login to add or remove it as a login item,
// or --list-items to print the menu bar items it can see.

import AppKit
import ApplicationServices
import CoreAudio
import ServiceManagement

let calibratedSize = NSSize(width: 1710, height: 1107)  // screen menubar-bg.png was taken on
let bandScale: CGFloat = 2          // menubar-bg.png pixels per point
let patchHeight: CGFloat = 33       // the menu bar is 34 pt tall; stay off its bottom edge
let pillHalfWidth: CGFloat = 20     // the pill is ~36 pt wide around the 16 pt item Accessibility reports
let pillLinger: TimeInterval = 4    // keep the pill covered while it fades out
let dryRun = CommandLine.arguments.contains("--dry-run")   // fake 3 s of mic use and log what's found

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

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func processes() -> [AudioObjectID] { objectList(system, kAudioHardwarePropertyProcessObjectList) }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// Whether a device is real hardware, or an aggregate that contains some. Virtual devices such
    /// as BlackHole or Loopback take input without macOS showing the microphone indicator.
    static func isPhysical(_ device: AudioObjectID, depth: Int = 0) -> Bool {
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case UInt32(kAudioDeviceTransportTypeVirtual):
            return false
        case UInt32(kAudioDeviceTransportTypeAggregate):
            return depth < 2 && objectList(device, kAudioAggregateDevicePropertyActiveSubDeviceList)
                .contains { isPhysical($0, depth: depth + 1) }
        default:
            return true
        }
    }

    /// PIDs of processes currently recording from a physical input device. A process whose device
    /// list can't be read still counts, so an unreadable list never leaves the pill uncovered.
    static func recordingPIDs() -> [pid_t] {
        processes()
            .filter { process in
                guard uint32(process, kAudioProcessPropertyIsRunningInput) != 0 else { return false }
                let devices = objectList(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
                return devices.isEmpty || devices.contains { isPhysical($0) }
            }
            .map { pid_t(bitPattern: uint32($0, kAudioProcessPropertyPID)) }
    }
}

// MARK: - Menu bar items (Accessibility)

struct MenuItem {
    let element: AXUIElement
    let identifier: String
    let label: String     // for the log
    let frame: CGRect     // global coordinates, top-left origin like window bounds
}

enum MenuBarItems {
    static let pillIdentifier = "com.apple.menuextra.audiovideo"

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func item(_ element: AXUIElement) -> MenuItem? {
        guard let f = frame(element) else { return nil }
        let identifier = string(element, kAXIdentifierAttribute)
        let label = "id='\(identifier)' desc='\(string(element, kAXDescriptionAttribute))' "
            + String(format: "x %.1f–%.1f y %.1f h %.1f", f.minX, f.maxX, f.minY, f.height)
        return MenuItem(element: element, identifier: identifier, label: label, frame: f)
    }

    /// The items MenuBarAgent draws. Its extras bar lists anonymous slots; the named item sits at
    /// each slot's center, so hit-test there to get it.
    static func systemItems() -> [MenuItem] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return [] }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let bar = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let slots = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        return slots.compactMap { slot in
            guard let slotItem = item(slot) else { return nil }
            if !slotItem.identifier.isEmpty { return slotItem }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(slotItem.frame.midX), Float(slotItem.frame.midY), &hit) == .success,
                  let hit, let named = item(hit), !named.identifier.isEmpty else { return slotItem }
            return named
        }
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
    private var micOn = false
    private var micChanged = Date.distantPast
    private var axTrusted = false
    private var pillItem: MenuItem?       // the pill, found through Accessibility
    private var dumpedItems = false
    private var fakeMicUntil: Date?
    private let pill = Patch()
    private var fastTimer: Timer?
    private var watched = Set<AudioObjectID>()
    private var barVisible = true
    private var ticks = 0
    private var loggedCover = false

    private var screen: NSScreen? { NSScreen.screens.first { $0.frame.size == calibratedSize } }

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
        axTrusted = AXIsProcessTrusted()
        if !axTrusted, !dryRun {
            // Shows the system prompt that sends the user to Privacy & Security > Accessibility.
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            axTrusted = AXIsProcessTrustedWithOptions(prompt)
        }
        log("accessibility \(axTrusted ? "granted" : "not granted; nothing will be covered until it is")")
        micOn = !Mic.recordingPIDs().isEmpty
        micChanged = micOn ? Date() : .distantPast
        watchAudio()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.slowTick() }
        if dryRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.fakeMicUntil = Date().addingTimeInterval(3)
                self?.evaluate()
            }
        }
        evaluate()
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
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted {
            axTrusted = trusted
            log("accessibility \(trusted ? "granted" : "revoked")")
        }
    }

    /// Finds the pill among the items MenuBarAgent draws. Logs every item once per recording if
    /// it isn't there, so a changed identifier shows up in the log.
    private func locatePill() {
        let items = MenuBarItems.systemItems()
        if let found = items.first(where: { $0.identifier == MenuBarItems.pillIdentifier }) {
            if pillItem == nil { log("pill: \(found.label)") }
            pillItem = found
        } else if !dumpedItems, Date().timeIntervalSince(micChanged) > 1.5 {
            dumpedItems = true
            log("pill not found; menu bar items:\(items.isEmpty ? " none" : "")")
            for item in items { log("  \(item.label)") }
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
            if on {
                log("mic on: \(pids.map(appName).joined(separator: ", "))")
                pillItem = nil
                dumpedItems = false
                loggedCover = false
                if axTrusted { locatePill() }
            } else {
                // Keep pillItem: the pill fades out in place, so its last frame is right for the linger.
                log("mic off")
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
            pillItem = nil
            if dryRun { log("dry run done"); NSApp.terminate(nil) }
            return
        }
        // Follow the pill as the menu bar reflows; look for it again if its element went away.
        if micOn, axTrusted, ticks % 4 == 2 {
            if let p = pillItem, let f = MenuBarItems.frame(p.element) {
                pillItem = MenuItem(element: p.element, identifier: p.identifier, label: p.label, frame: f)
            } else {
                locatePill()
            }
        }
        update()
    }

    private func update() {
        guard let s = screen else { pill.hide(); return }
        let top = s.frame.maxY
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? top
        let covering = micOn || Date().timeIntervalSince(micChanged) < pillLinger
        guard barVisible, covering, let p = pillItem,
              abs(p.frame.minY - (primaryTop - top)) < 12, p.frame.minX >= s.frame.minX, p.frame.maxX <= s.frame.maxX
        else { pill.hide(); return }
        let half = max(pillHalfWidth, p.frame.width / 2 + 4)
        let r = NSRect(x: p.frame.midX - half, y: top - patchHeight, width: half * 2, height: patchHeight)
        pill.show(r, key: "pill") { makeImage(r, on: s, feather: Feather(left: 2, right: 2, bottom: 3)) }
        if micOn, !loggedCover {
            loggedCover = true
            log("covering \(describe(r))")
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
}

// MARK: - Command-line flags

if CommandLine.arguments.contains("--list-items") {
    // Prints the menu bar items MicPatch can see; the pill shows up while the mic is in use.
    guard AXIsProcessTrusted() else { print("Accessibility not granted for this process"); exit(1) }
    for item in MenuBarItems.systemItems() {
        print("\(item.identifier == MenuBarItems.pillIdentifier ? "PILL " : "     ")\(item.label)")
    }
    exit(0)
}

if let flag = ["--register-login", "--unregister-login"].first(where: CommandLine.arguments.contains) {
    let register = flag == "--register-login"
    do {
        if register { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        let status: String
        switch SMAppService.mainApp.status {
        case .enabled: status = "enabled"
        case .requiresApproval: status = "waiting for approval in System Settings > General > Login Items"
        case .notRegistered: status = "not registered"
        default: status = "not found"
        }
        print("\(register ? "Registered" : "Unregistered") \(Bundle.main.bundlePath) as a login item (\(status))")
        exit(0)
    } catch {
        print("Could not \(register ? "register" : "unregister") login item: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
