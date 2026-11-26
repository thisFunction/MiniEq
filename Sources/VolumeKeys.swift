import AppKit
import ApplicationServices
import SwiftUI

/// Makes the keyboard's volume keys (up, down, mute) turn MiniEQ's Volume knob.
///
/// It watches only those media keys — never ordinary typing — but macOS still requires the
/// Accessibility permission for an app to catch them. The keys go back to controlling the Mac's
/// own volume whenever MiniEQ isn't processing sound, and ⌥ + a volume key still opens Sound
/// settings as usual.
final class VolumeKeys {
    enum Key { case up, down, mute }

    /// Called on the main thread for every press (and key repeat). `fine` = ⌥⇧ held.
    var onKey: ((Key, _ fine: Bool) -> Void)?
    /// Asked before swallowing a key; return false to let macOS handle it.
    var shouldHandle: (() -> Bool)?
    /// Called once the keys are hooked up.
    var onEnabled: (() -> Void)?

    private(set) var isEnabled = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustTimer: Timer?

    /// Hooks up the keys now if MiniEQ is allowed, otherwise (optionally) shows the macOS
    /// prompt and keeps checking, so the keys start working the moment you allow it.
    func start(prompt: Bool) {
        if AXIsProcessTrusted() {
            installTap()
            return
        }
        if prompt {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.installTap()
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let systemDefinedEvents = CGEventMask(1) << 14          // NX_SYSDEFINED: media keys
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: systemDefinedEvents,
                                           callback: volumeKeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Diagnostics.log("Volume keys: couldn't watch the keyboard (is MiniEQ allowed in Accessibility?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        isEnabled = true
        Diagnostics.log("Volume keys now control MiniEQ")
        onEnabled?()
    }

    /// macOS switches a tap off if it ever stalls; turn it straight back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event (macOS then leaves its own volume alone).
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard event.type.rawValue == 14,                          // NX_SYSDEFINED
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else { return false } // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        let data = nsEvent.data1
        let key: Key
        switch (data & 0xFFFF_0000) >> 16 {
        case 0: key = .up                                          // NX_KEYTYPE_SOUND_UP
        case 1: key = .down                                        // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute                                        // NX_KEYTYPE_MUTE
        default: return false
        }
        guard shouldHandle?() ?? false else { return false }
        let modifiers = nsEvent.modifierFlags
        if modifiers.contains(.option) && !modifiers.contains(.shift) { return false }   // ⌥ + key: Sound settings
        let isKeyDown = (data & 0xFF00) >> 8 == 0x0A
        if isKeyDown {
            let fine = modifiers.contains(.option) && modifiers.contains(.shift)
            DispatchQueue.main.async { self.onKey?(key, fine) }
        }
        return true                                                // swallow key-down and key-up
    }
}

private func volumeKeyTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                  _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passThrough }
    let keys = Unmanaged<VolumeKeys>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        keys.reenable()
        return passThrough
    }
    return keys.handle(event) ? nil : passThrough
}

// MARK: - On-screen volume display

/// A small pop-up showing MiniEQ's volume for a moment after a volume key is pressed
/// (macOS doesn't show its own, since MiniEQ handles those keys).
final class VolumeHUD {
    private let state = VolumeHUDState()
    private var panel: NSPanel?
    private var generation = 0

    func show(volume: Double) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.volume = volume
        position(panel)
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.12)) { state.visible = true }

        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.generation == shown else { return }
            withAnimation(.easeIn(duration: 0.3)) { self.state.visible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 270, height: 88)               // includes room for the shadow
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: VolumeHUDView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    /// Top-right, just under the menu bar — where macOS shows its own volume pop-up.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width + 8, y: area.maxY - size.height + 12))
    }
}

final class VolumeHUDState: ObservableObject {
    @Published var volume = 0.0
    @Published var visible = false
}

struct VolumeHUDView: View {
    @ObservedObject var state: VolumeHUDState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule()
                        .fill(Color.miniAccent)
                        .frame(width: max(0, geo.size.width * min(max(state.volume, 0), 1)))
                }
            }
            .frame(height: 6)
            Text(KnobSpec.volume.format(state.volume))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(width: 230, height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .opacity(state.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
