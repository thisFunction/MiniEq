import SwiftUI
import AppKit

@main
struct MiniEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
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
    // Fine-tuning bands set only by dragging the tone curve (no knobs).
    @Published var lowMid: Double { didSet { knobsChanged() } }
    @Published var highMid: Double { didSet { knobsChanged() } }
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
        lowMid = saved("lowMid", 0, -Tone.maxDB...Tone.maxDB)
        highMid = saved("highMid", 0, -Tone.maxDB...Tone.maxDB)
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
        defaults.set(lowMid, forKey: "lowMid")
        defaults.set(highMid, forKey: "highMid")
    }

    private func pushKnobsToEngine() {
        engine.setKnobs(volume: volume, balance: balance, bass: bass, lowMid: lowMid, mid: mid,
                        highMid: highMid, treble: treble)
    }
}

/// The menu bar icon follows the Volume knob: its arc fills and its pointer turns as you
/// change MiniEQ's volume (empty and pointing bottom-left at 0 %, full at 100 %).
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: MenuBarIcon.image(volume: model.volume))
            .accessibilityLabel("MiniEQ, volume \(KnobSpec.volume.format(model.volume))")
    }
}

/// A tiny knob drawn as a template image, so it matches the menu bar in light and dark mode.
enum MenuBarIcon {
    private static var cache: [Int: NSImage] = [:]

    static func image(volume: Double) -> NSImage {
        let step = Int((min(max(volume, 0), 1) * 50).rounded())   // 2 % steps are plenty at this size
        if let cached = cache[step] { return cached }
        let fraction = CGFloat(step) / 50
        // Flipped (y-down) drawing, so angles grow clockwise; the knob's arc runs 135° to 405°.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            func arc(to end: CGFloat, alpha: CGFloat) {
                guard end - 135 > 0.5 else { return }
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: 6.9, startAngle: 135, endAngle: end, clockwise: false)
                path.lineWidth = 1.7
                path.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            arc(to: 405, alpha: 0.32)                    // faint track
            arc(to: 135 + 270 * fraction, alpha: 1)      // current volume
            let angle = (135 + 270 * fraction) * .pi / 180
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: center.x + cos(angle) * 1.0, y: center.y + sin(angle) * 1.0))
            pointer.line(to: NSPoint(x: center.x + cos(angle) * 4.3, y: center.y + sin(angle) * 4.3))
            pointer.lineWidth = 1.8
            pointer.lineCapStyle = .round
            NSColor.black.setStroke()
            pointer.stroke()
            return true
        }
        image.isTemplate = true
        cache[step] = image
        return image
    }
}
