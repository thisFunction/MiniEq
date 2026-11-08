import SwiftUI
import AppKit

@main
struct MiniEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: appDelegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("MiniEQ")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitSignals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashGuard.install()
        routeQuitSignalsThroughNormalQuit()
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// `kill`, `pkill` and logout send SIGTERM/SIGINT/SIGHUP. Turn them into a normal quit so the
    /// audio tap is always removed on the way out.
    private func routeQuitSignalsThroughNormalQuit() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            quitSignals.append(source)
        }
    }
}

/// The five knobs (saved between launches) plus the engine's status.
final class AppModel: ObservableObject {
    @Published var volume: Double { didSet { knobsChanged() } }
    @Published var balance: Double { didSet { knobsChanged() } }
    @Published var bass: Double { didSet { knobsChanged() } }
    @Published var mid: Double { didSet { knobsChanged() } }
    @Published var treble: Double { didSet { knobsChanged() } }
    @Published private(set) var status: EngineStatus = .starting

    let engine = AudioEngine()

    init() {
        func saved(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let value = UserDefaults.standard.object(forKey: key) as? Double, value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        volume = saved("volume", 1, 0...1)
        balance = saved("balance", 0, -1...1)
        bass = saved("bass", 0, -Tone.maxDB...Tone.maxDB)
        mid = saved("mid", 0, -Tone.maxDB...Tone.maxDB)
        treble = saved("treble", 0, -Tone.maxDB...Tone.maxDB)
        engine.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.status = status }
        }
        pushKnobsToEngine()
    }

    func launch() {
        let permission = CapturePermission.current()
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        Diagnostics.log("MiniEQ started (macOS \(macOS)); system audio permission: \(permission)")
        switch permission {
        case .authorized, .unavailable:
            engine.start()
        case .denied:
            status = .permissionDenied
        case .notDetermined:
            status = .waitingForPermission
            let asked = CapturePermission.request { [weak self] granted in
                guard let self else { return }
                Diagnostics.log("Permission prompt answered: \(granted ? "allowed" : "denied")")
                if granted { self.engine.start() } else { self.status = .permissionDenied }
            }
            if !asked { engine.start() }
        }
    }

    func shutdown() {
        engine.shutdown()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A permission granted in System Settings only takes effect after a relaunch.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func knobsChanged() {
        pushKnobsToEngine()
        let defaults = UserDefaults.standard
        defaults.set(volume, forKey: "volume")
        defaults.set(balance, forKey: "balance")
        defaults.set(bass, forKey: "bass")
        defaults.set(mid, forKey: "mid")
        defaults.set(treble, forKey: "treble")
    }

    private func pushKnobsToEngine() {
        engine.setKnobs(volume: volume, balance: balance, bass: bass, mid: mid, treble: treble)
    }
}

/// A small knob drawn as a template image, so it matches the menu bar in light and dark mode.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.25, dy: 2.25))
            ring.lineWidth = 1.5
            ring.stroke()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let angle = CGFloat.pi * 0.75   // pointing up-left, like a knob at "10 o'clock"
            let pointer = NSBezierPath()
            pointer.lineWidth = 1.8
            pointer.lineCapStyle = .round
            pointer.move(to: NSPoint(x: center.x + cos(angle) * 1.6, y: center.y + sin(angle) * 1.6))
            pointer.line(to: NSPoint(x: center.x + cos(angle) * 5.0, y: center.y + sin(angle) * 5.0))
            pointer.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
