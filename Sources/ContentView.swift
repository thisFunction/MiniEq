import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var level: Float = 0
    let meter = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                KnobView(spec: .volume, value: $model.volume)
                KnobView(spec: .balance, value: $model.balance)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: 64)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
                KnobView(spec: .bass, value: $model.bass)
                KnobView(spec: .mid, value: $model.mid)
                KnobView(spec: .treble, value: $model.treble)
            }
            ToneCurveView(bass: model.bass, mid: model.mid, treble: model.treble)
                .padding(.vertical, 6)
                .padding(.trailing, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            Divider()
            footer
        }
        .frame(width: 380)
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .onReceive(meter) { _ in level = model.engine.level }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            switch model.status {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…")
            case .running(let device):
                Circle()
                    .fill(level > 0.0005 ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .help(level > 0.0005 ? "Sound is flowing through MiniEQ" : "Nothing is playing")
                Text(device)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .waitingForPermission:
                Image(systemName: "hand.raised")
                Text("Click Allow in the system prompt")
            case .permissionDenied:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Turn on MiniEQ under System Audio Recording, then relaunch.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open Settings") { model.openPrivacySettings() }
                        Button("Relaunch") { model.relaunch() }
                    }
                    .controlSize(.small)
                }
            case .problem(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
