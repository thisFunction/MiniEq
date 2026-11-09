import SwiftUI

/// A live graph of what the Bass, Mid and Treble knobs are doing to the sound,
/// computed from the very same filters the audio thread uses.
struct ToneCurveView: View {
    let bass: Double
    let mid: Double
    let treble: Double

    private static let minHz = 20.0
    private static let maxHz = 20_000.0
    private static let rangeDB = 15.0            // graph shows ±15 dB
    private static let graphRate = 48_000.0      // sample rate used for drawing

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 24, y: 5, width: size.width - 28, height: size.height - 19)

            func x(_ hz: Double) -> CGFloat {
                let t = log10(hz / Self.minHz) / log10(Self.maxHz / Self.minHz)
                return plot.minX + CGFloat(t) * plot.width
            }
            func y(_ db: Double) -> CGFloat {
                let clamped = min(max(db, -Self.rangeDB), Self.rangeDB)
                let t = (Self.rangeDB - clamped) / (2 * Self.rangeDB)
                return plot.minY + CGFloat(t) * plot.height
            }
            let filters = Tone.filters(bass: bass, mid: mid, treble: treble, sampleRate: Self.graphRate)
            func totalDB(_ hz: Double) -> Double {
                filters.reduce(0.0) { $0 + $1.magnitudeDB(at: hz, sampleRate: Self.graphRate) }
            }

            // Grid
            var grid = Path()
            for hz in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
                grid.move(to: CGPoint(x: x(hz), y: plot.minY))
                grid.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
            }
            for db in [-12.0, -6, 6, 12] {
                grid.move(to: CGPoint(x: plot.minX, y: y(db)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
            }
            context.stroke(grid, with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: plot.minX, y: y(0)))
            zeroLine.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
            context.stroke(zeroLine, with: .color(Color.primary.opacity(0.2)), lineWidth: 1)

            // Labels
            for db in [-12, -6, 0, 6, 12] {
                let label = db > 0 ? "+\(db)" : "\(db)"
                context.draw(Text(label).font(.system(size: 8)).foregroundColor(.secondary),
                             at: CGPoint(x: plot.minX - 4, y: y(Double(db))), anchor: .trailing)
            }
            for (hz, label) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
                context.draw(Text(label).font(.system(size: 8)).foregroundColor(.secondary),
                             at: CGPoint(x: x(hz), y: plot.maxY + 3), anchor: .top)
            }

            // The curve, with a soft fill back to 0 dB
            var curve = Path()
            let steps = 160
            for i in 0...steps {
                let hz = Self.minHz * pow(Self.maxHz / Self.minHz, Double(i) / Double(steps))
                let point = CGPoint(x: x(hz), y: y(totalDB(hz)))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
            area.addLine(to: CGPoint(x: plot.minX, y: y(0)))
            area.closeSubpath()
            context.fill(area, with: .color(Color.accentColor.opacity(0.16)))
            context.stroke(curve, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

            // A dot where each knob does its work
            for hz in [Tone.bassHz, Tone.midHz, Tone.trebleHz] {
                let center = CGPoint(x: x(hz), y: y(totalDB(hz)))
                let dot = Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
                context.fill(dot, with: .color(Color.accentColor))
            }
        }
        .frame(height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tone curve")
        .accessibilityValue("Bass \(KnobSpec.bass.format(bass)), Mid \(KnobSpec.mid.format(mid)), Treble \(KnobSpec.treble.format(treble))")
    }
}
