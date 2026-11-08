import SwiftUI
import AppKit

/// Everything that makes one knob different from another.
struct KnobSpec {
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let bipolar: Bool                  // value arc grows from the center (Balance, EQ)
    let step: Double                   // for VoiceOver / accessibility adjustments
    let format: (Double) -> String

    static let volume = KnobSpec(title: "Volume", range: 0...1, defaultValue: 1, bipolar: false, step: 0.05) {
        "\(Int(($0 * 100).rounded()))%"
    }

    static let balance = KnobSpec(title: "Balance", range: -1...1, defaultValue: 0, bipolar: true, step: 0.1) { value in
        let amount = Int((abs(value) * 100).rounded())
        if amount == 0 { return "Center" }
        return value < 0 ? "L \(amount)" : "R \(amount)"
    }

    static let bass = tone("Bass")
    static let mid = tone("Mid")
    static let treble = tone("Treble")

    private static func tone(_ title: String) -> KnobSpec {
        KnobSpec(title: title, range: -Tone.maxDB...Tone.maxDB, defaultValue: 0, bipolar: true, step: 1) { value in
            abs(value) < 0.05 ? "0 dB" : String(format: "%+.1f dB", value)
        }
    }
}

/// A rotary knob: drag up/down (hold ⌥ for fine control), scroll, or double-click to reset.
struct KnobView: View {
    let spec: KnobSpec
    @Binding var value: Double
    @State private var valueAtDragStart: Double = 0

    private var span: Double { spec.range.upperBound - spec.range.lowerBound }
    private var fraction: Double { min(max((value - spec.range.lowerBound) / span, 0), 1) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                KnobFace(fraction: fraction, origin: spec.bipolar ? 0.5 : 0)
                KnobMouseArea(
                    onBegin: { valueAtDragStart = value },
                    onDrag: { travel in set(valueAtDragStart + Double(travel) * span / 160, snapToDefault: true) },
                    onScroll: { delta in set(value + Double(delta) * span / 300, snapToDefault: false) },
                    onReset: { value = spec.defaultValue }
                )
            }
            .frame(width: 54, height: 54)

            Text(spec.format(value))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(spec.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(width: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.title)
        .accessibilityValue(spec.format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + spec.step, snapToDefault: false)
            case .decrement: set(value - spec.step, snapToDefault: false)
            @unknown default: break
            }
        }
    }

    private func set(_ proposed: Double, snapToDefault: Bool) {
        var v = min(max(proposed, spec.range.lowerBound), spec.range.upperBound)
        // A gentle detent at the default (center / 100%) makes "flat" easy to find by feel.
        if snapToDefault && abs(v - spec.defaultValue) < span * 0.02 { v = spec.defaultValue }
        if v != value { value = v }
    }
}

/// The drawing: a 270° track, the value arc, a soft cap and a pointer.
struct KnobFace: View {
    let fraction: Double   // 0…1
    let origin: Double     // where the value arc starts (0 or 0.5)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = size * 0.075
            let start = 0.125 + 0.75 * min(origin, fraction)
            let end = 0.125 + 0.75 * max(origin, fraction)
            ZStack {
                Circle()
                    .trim(from: 0.125, to: 0.875)
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(90))
                if end - start > 0.0005 {
                    Circle()
                        .trim(from: start, to: end)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(90))
                }
                Circle()
                    .fill(LinearGradient(colors: [.knobCapTop, .knobCapBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .padding(line * 2.1)
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: max(2, line * 0.75), height: size * 0.16)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension Color {
    static let knobCapTop = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.36, alpha: 1) : NSColor(white: 1.0, alpha: 1)
    })
    static let knobCapBottom = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.88, alpha: 1)
    })
}

// MARK: - Mouse handling (AppKit gives us raw drag deltas, scroll wheel and double-click)

struct KnobMouseArea: NSViewRepresentable {
    var onBegin: () -> Void
    var onDrag: (_ travel: CGFloat) -> Void      // total points moved upward since mouse-down
    var onScroll: (_ delta: CGFloat) -> Void     // positive = up / away from you
    var onReset: () -> Void

    func makeNSView(context: Context) -> KnobMouseView {
        let view = KnobMouseView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: KnobMouseView, context: Context) {
        view.handlers = self
    }
}

final class KnobMouseView: NSView {
    var handlers: KnobMouseArea?
    private var travel: CGFloat = 0
    private var ignoreDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        travel = 0
        if event.clickCount >= 2 {
            ignoreDrag = true
            handlers?.onReset()
            return
        }
        ignoreDrag = false
        handlers?.onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoreDrag else { return }
        let fine: CGFloat = event.modifierFlags.contains(.option) ? 0.2 : 1
        travel -= event.deltaY * fine          // deltaY is positive when the mouse moves down
        handlers?.onDrag(travel)
    }

    override func mouseUp(with event: NSEvent) {
        ignoreDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }   // undo "natural scrolling"
        if !event.hasPreciseScrollingDeltas { delta *= 6 }          // mouse wheel clicks → points
        if event.modifierFlags.contains(.option) { delta *= 0.2 }
        handlers?.onScroll(delta)
    }
}
