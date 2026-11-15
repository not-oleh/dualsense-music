import AppKit

/// Menu bar front end. It runs the engine as a child copy of this same program and restarts
/// it whenever a choice changes, so the engine needs no live reconfiguration.
/// shortcut: if this app is force-killed the engine keeps running; `pkill dualsense-music` stops it.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var child: Process?
    private var status = "Starting…"
    private let saved = UserDefaults.standard

    private var on: Bool { get { saved.object(forKey: "on") as? Bool ?? true } set { saved.set(newValue, forKey: "on") } }
    private var source: String? { get { saved.string(forKey: "source") } set { saved.set(newValue, forKey: "source") } }
    private var gain: Float { get { saved.object(forKey: "gain") as? Float ?? 0.7 } set { saved.set(newValue, forKey: "gain") } }
    private var raw: Bool { get { saved.bool(forKey: "raw") } set { saved.set(newValue, forKey: "raw") } }

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "DualSense Music")
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        restart()
    }

    // SIGTERM lets the engine stop the vibration and put Game Mode back.
    func applicationWillTerminate(_ note: Notification) { stop() }

    private func stop() {
        guard let c = child else { return }
        c.terminationHandler = nil; child = nil
        c.terminate(); c.waitUntilExit()
    }

    private func restart() {
        stop()
        guard on else { status = "Off"; return }
        let p = Process(), pipe = Pipe()
        p.executableURL = Bundle.main.executableURL
        p.arguments = (source.map { ["--app", $0] } ?? []) + ["--gain", "\(gain)"] + (raw ? ["--raw"] : [])
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            // The engine prints one plain line per event; the latest one is the status.
            guard let line = String(data: h.availableData, encoding: .utf8)?.split(separator: "\n").last else { return }
            let short = String(line).components(separatedBy: ". ").first!   // "Running. Bass in your…" -> "Running"
            DispatchQueue.main.async { if self?.child === p { self?.status = short } }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { if self?.child === p { self?.child = nil; self?.status = "Stopped. " + (self?.status ?? "") } }
        }
        status = "Starting…"
        do { try p.run(); child = p } catch { status = "Could not start: \(error.localizedDescription)" }
    }

    // Rebuilt each time the menu opens, so the list of apps is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, checked: Bool = false, to m: NSMenu = menu, _ action: (() -> Void)? = nil) {
            let i = NSMenuItem(title: title, action: action == nil ? nil : #selector(fire(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = action; i.state = checked ? .on : .off
            m.addItem(i)
        }
        func header(_ title: String) { menu.addItem(.separator()); add(title) }   // an item without an action shows greyed out

        add(status)
        add(on ? "Turn Off" : "Turn On") { [self] in on.toggle(); restart() }

        header("Feel sound from")
        add("Everything", checked: source == nil) { [self] in source = nil; restart() }
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { (name: $0.localizedName ?? $0.bundleIdentifier!, id: $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let s = source, !apps.contains(where: { $0.id == s }) { apps.append((name: "\(s) (not running)", id: s)) }
        for app in apps { add(app.name, checked: source == app.id) { [self] in source = app.id; restart() } }

        header("Strength")
        for (name, value) in [("Soft", 0.4), ("Normal", 0.7), ("Strong", 1.0)] as [(String, Float)] {
            add(name, checked: gain == value) { [self] in gain = value; restart() }
        }

        header("Mode")
        add("Standard", checked: !raw) { [self] in raw = false; restart() }
        add("Raw waveform (experimental)", checked: raw) { [self] in raw = true; restart() }

        menu.addItem(.separator())
        add("Quit DualSense Music") { NSApp.terminate(nil) }
    }

    @objc private func fire(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

    static func main() {
        let app = NSApplication.shared, delegate = MenuBarApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
        withExtendedLifetime(delegate) { app.run() }
    }
}
