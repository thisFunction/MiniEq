import SwiftUI
import AppKit

/// A live graph of what the tone bands are doing to the sound, computed from the very same
/// filters the audio thread uses.
///
/// It's also a control with five drag points — Bass, Low mid, Mid, High mid and Treble.
/// Drag the line up or down to change the band whose point is nearest the pointer (hold ⌥ for
/// fine moves), scroll over it, or double-click to reset that band. 0 dB is magnetic: a point
/// dragged or scrolled through neutral stops there for a moment. Bass, Mid and Treble also
/// have knobs, which move along; Low mid and High mid live only here.
struct ToneCurveView: View {
    @Binding var bass: Double
    @Binding var lowMid: Double
    @Binding var mid: Double
    @Binding var highMid: Double
    @Binding var treble: Double

    @State private var hovered: Band?
    @State private var dragging: Band?
    @State private var rawAtDragStart = 0.0      // drag position in "notch space" (see snap)

    /// How far (in points of pointer travel) a dragged point stays stuck at 0 dB.
    private static let notchPoints = 10.0

    enum Band: CaseIterable {
        case bass, lowMid, mid, highMid, treble     // left to right

        /// Where each band's handle sits: on the flat part of the shelves and at the top of the
        /// bells, so the line under the handle follows the pointer almost one-to-one.
        var handleHz: Double {
            switch self {
            case .bass: return 40
            case .lowMid: return Tone.lowMidHz
            case .mid: return Tone.midHz
            case .highMid: return Tone.highMidHz
            case .treble: return 15_000
            }
        }

        var title: String {
            switch self {
            case .bass: return "Bass"
            case .lowMid: return "Low mid"
            case .mid: return "Mid"
            case .highMid: return "High mid"
            case .treble: return "Treble"
            }
        }
    }

    private static let minHz = 20.0
    private static let maxHz = 20_000.0
    private static let rangeDB = 15.0            // graph shows ±15 dB
    private static let graphRate = 48_000.0      // sample rate used for drawing

    // MARK: Geometry (shared by drawing and mouse handling)

    /// The graph spans the full width, so the handles can be spaced evenly edge to edge.
    private static func plot(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: 5, width: max(1, size.width), height: max(1, size.height - 19))
    }

    /// Frequencies pinned to evenly spaced spots across the graph: the two edges and the five
    /// handles, which land at 1/6, 2/6 … 5/6 of the width — equal gaps everywhere.
    private static let anchorHz: [Double] = [minHz] + Band.allCases.map { $0.handleHz } + [maxHz]

    /// Horizontal position (0…1) of a frequency: logarithmic between neighbouring anchors,
    /// so the scale is stretched a little here and there to keep the handles evenly spaced.
    /// (Only the drawing is stretched — the sound is not affected.)
    private static func fraction(of hz: Double) -> Double {
        let f = min(max(hz, minHz), maxHz)
        let segments = Double(anchorHz.count - 1)
        for k in 0..<(anchorHz.count - 1) where f <= anchorHz[k + 1] {
            let local = log(f / anchorHz[k]) / log(anchorHz[k + 1] / anchorHz[k])
            return (Double(k) + local) / segments
        }
        return 1
    }

    /// The frequency at a horizontal position (0…1) — the inverse of `fraction(of:)`.
    private static func frequency(atFraction t: Double) -> Double {
        let segments = Double(anchorHz.count - 1)
        let position = min(max(t, 0), 1) * segments
        let k = min(Int(position), anchorHz.count - 2)
        return anchorHz[k] * pow(anchorHz[k + 1] / anchorHz[k], position - Double(k))
    }

    private static func x(_ hz: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(fraction(of: hz)) * plot.width
    }

    private static func y(_ db: Double, _ plot: CGRect) -> CGFloat {
        let clamped = min(max(db, -rangeDB), rangeDB)
        let t = (rangeDB - clamped) / (2 * rangeDB)
        return plot.minY + CGFloat(t) * plot.height
    }

    /// Which band a point on the graph belongs to: whichever handle is horizontally nearest.
    private static func band(at point: CGPoint, in size: CGSize) -> Band {
        let rect = Self.plot(in: size)
        let t = Double((point.x - rect.minX) / rect.width)
        return Band.allCases.min { abs(fraction(of: $0.handleHz) - t) < abs(fraction(of: $1.handleHz) - t) } ?? .mid
    }

    // MARK: Values

    private func value(of band: Band) -> Double {
        switch band {
        case .bass: return bass
        case .lowMid: return lowMid
        case .mid: return mid
        case .highMid: return highMid
        case .treble: return treble
        }
    }

    /// dB per point of vertical pointer travel: one point of drag = one point on the graph.
    private static func dbPerPoint(_ size: CGSize) -> Double {
        2 * rangeDB / Double(plot(in: size).height)
    }

    /// The magnetic notch at 0 dB. While dragging, the pointer has to travel through a small
    /// dead zone (`notch` dB wide) before the value leaves 0. `snap` turns a drag position into
    /// a value; `unsnap` is its inverse, so grabbing a point never makes it jump.
    private static func snap(_ raw: Double, notch: Double) -> Double {
        if abs(raw) <= notch / 2 { return 0 }
        return raw > 0 ? raw - notch / 2 : raw + notch / 2
    }

    private static func unsnap(_ value: Double, notch: Double) -> Double {
        if value == 0 { return 0 }
        return value > 0 ? value + notch / 2 : value - notch / 2
    }

    private func set(_ band: Band, to proposed: Double) {
        let v = min(max(proposed, -Tone.maxDB), Tone.maxDB)
        guard v != value(of: band) else { return }
        if v == 0 {
            // A light tap on Force Touch trackpads when a point lands on neutral.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        switch band {
        case .bass: if v != bass { bass = v }
        case .lowMid: if v != lowMid { lowMid = v }
        case .mid: if v != mid { mid = v }
        case .highMid: if v != highMid { highMid = v }
        case .treble: if v != treble { treble = v }
        }
    }

    private func label(for band: Band) -> String {
        "\(band.title) \(KnobSpec.bass.format(value(of: band)))"
    }

    // MARK: View

    var body: some View {
        Canvas { context, size in
            let plot = Self.plot(in: size)
            let filters = Tone.filters(bass: bass, lowMid: lowMid, mid: mid, highMid: highMid, treble: treble,
                                       sampleRate: Self.graphRate)
            func totalDB(_ hz: Double) -> Double {
                filters.reduce(0.0) { $0 + $1.magnitudeDB(at: hz, sampleRate: Self.graphRate) }
            }
            let focus = dragging ?? hovered

            // Grid
            var grid = Path()
            for band in Band.allCases {
                grid.move(to: CGPoint(x: Self.x(band.handleHz, plot), y: plot.minY))
                grid.addLine(to: CGPoint(x: Self.x(band.handleHz, plot), y: plot.maxY))
            }
            for db in [-12.0, -6, 6, 12] {
                grid.move(to: CGPoint(x: plot.minX, y: Self.y(db, plot)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: Self.y(db, plot)))
            }
            context.stroke(grid, with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: plot.minX, y: Self.y(0, plot)))
            zeroLine.addLine(to: CGPoint(x: plot.maxX, y: Self.y(0, plot)))
            // The 0 dB line lights up while the point you're dragging sits on it.
            let onNeutral = dragging.map { value(of: $0) == 0 } ?? false
            context.stroke(zeroLine, with: .color(onNeutral ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.2)),
                           lineWidth: onNeutral ? 1.5 : 1)

            // Frequency markers
            for (hz, text) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
                context.draw(Text(text).font(.system(size: 8)).foregroundColor(.secondary),
                             at: CGPoint(x: Self.x(hz, plot), y: plot.maxY + 3), anchor: .top)
            }

            // The curve, with a soft fill back to 0 dB
            var curve = Path()
            let steps = 190
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let hz = Self.frequency(atFraction: t)
                let point = CGPoint(x: plot.minX + CGFloat(t) * plot.width, y: Self.y(totalDB(hz), plot))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: plot.maxX, y: Self.y(0, plot)))
            area.addLine(to: CGPoint(x: plot.minX, y: Self.y(0, plot)))
            area.closeSubpath()
            context.fill(area, with: .color(Color.accentColor.opacity(0.16)))
            context.stroke(curve, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

            // Handles: one per band; the one under the pointer (or being dragged) grows.
            for band in Band.allCases {
                let center = CGPoint(x: Self.x(band.handleHz, plot), y: Self.y(totalDB(band.handleHz), plot))
                let isFocus = band == focus
                if isFocus {
                    var guide = Path()
                    guide.move(to: CGPoint(x: center.x, y: plot.minY))
                    guide.addLine(to: CGPoint(x: center.x, y: plot.maxY))
                    context.stroke(guide, with: .color(Color.accentColor.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    let halo = CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)
                    context.fill(Path(ellipseIn: halo), with: .color(Color.accentColor.opacity(0.22)))
                }
                let r: CGFloat = isFocus ? 4 : 2.5
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Color.accentColor))
            }
        }
        .frame(height: 92)
        .overlay(
            CurveMouseArea(
                onHover: { point, size in
                    hovered = point.map { Self.band(at: $0, in: size) }
                },
                onBegin: { point, size in
                    let band = Self.band(at: point, in: size)
                    dragging = band
                    let notch = Self.notchPoints * Self.dbPerPoint(size)
                    rawAtDragStart = Self.unsnap(value(of: band), notch: notch)
                },
                onDrag: { travel, size in
                    guard let band = dragging else { return }
                    let perPoint = Self.dbPerPoint(size)
                    let raw = rawAtDragStart + Double(travel) * perPoint
                    set(band, to: Self.snap(raw, notch: Self.notchPoints * perPoint))
                },
                onEnd: {
                    dragging = nil
                },
                onScroll: { point, delta, size in
                    let band = Self.band(at: point, in: size)
                    let old = value(of: band)
                    var new = old + Double(delta) * 2 * Tone.maxDB / 300
                    if (old > 0 && new < 0) || (old < 0 && new > 0) { new = 0 }   // stop at neutral on the way through
                    set(band, to: new)
                },
                onReset: { point, size in
                    set(Self.band(at: point, in: size), to: 0)
                }
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tone curve")
        .accessibilityValue(Band.allCases.map { label(for: $0) }.joined(separator: ", "))
    }
}

// MARK: - Mouse handling (AppKit gives raw drag deltas, hover, scroll and double-click)

struct CurveMouseArea: NSViewRepresentable {
    var onHover: (_ point: CGPoint?, _ size: CGSize) -> Void
    var onBegin: (_ point: CGPoint, _ size: CGSize) -> Void
    var onDrag: (_ travel: CGFloat, _ size: CGSize) -> Void       // points moved upward since mouse-down
    var onEnd: () -> Void
    var onScroll: (_ point: CGPoint, _ delta: CGFloat, _ size: CGSize) -> Void
    var onReset: (_ point: CGPoint, _ size: CGSize) -> Void

    func makeNSView(context: Context) -> CurveMouseView {
        let view = CurveMouseView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: CurveMouseView, context: Context) {
        view.handlers = self
    }
}

final class CurveMouseView: NSView {
    var handlers: CurveMouseArea?
    private var travel: CGFloat = 0
    private var ignoreDrag = false

    override var isFlipped: Bool { true }      // top-left origin, same as SwiftUI's Canvas
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseEntered(with event: NSEvent) { handlers?.onHover(location(event), bounds.size) }
    override func mouseMoved(with event: NSEvent) { handlers?.onHover(location(event), bounds.size) }
    override func mouseExited(with event: NSEvent) { handlers?.onHover(nil, bounds.size) }

    override func mouseDown(with event: NSEvent) {
        travel = 0
        if event.clickCount >= 2 {
            ignoreDrag = true
            handlers?.onReset(location(event), bounds.size)
            return
        }
        ignoreDrag = false
        handlers?.onBegin(location(event), bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoreDrag else { return }
        let fine: CGFloat = event.modifierFlags.contains(.option) ? 0.2 : 1
        travel -= event.deltaY * fine            // deltaY is positive when the mouse moves down
        handlers?.onDrag(travel, bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        ignoreDrag = false
        handlers?.onEnd()
        let point = location(event)
        handlers?.onHover(bounds.contains(point) ? point : nil, bounds.size)
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }   // undo "natural scrolling"
        if !event.hasPreciseScrollingDeltas { delta *= 6 }          // mouse wheel clicks → points
        if event.modifierFlags.contains(.option) { delta *= 0.2 }
        handlers?.onScroll(location(event), delta, bounds.size)
    }
}
