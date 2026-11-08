import Foundation
import AppKit
import CoreAudio
import AudioToolbox

enum EngineStatus: Equatable {
    case starting
    case running(device: String)
    case waitingForPermission
    case permissionDenied
    case problem(String)
}

/// Routes all system audio through MiniEQ:
///   1. A muted "process tap" captures everything every app plays (except MiniEQ itself).
///   2. A private aggregate device pairs that tap with your real output device.
///   3. Our IOProc reads the tap, applies the knobs, and writes to the real device.
/// Quitting MiniEQ removes the tap, so sound goes straight to the device again.
final class AudioEngine {
    static let routeUIDPrefix = "MiniEQ-"

    let shared = SharedParams()
    /// Called on the engine queue; AppModel hops to the main thread.
    var onStatus: ((EngineStatus) -> Void)?

    private let queue = DispatchQueue(label: "com.skoczylas.MiniEQ.engine", qos: .userInitiated)

    private var wantsRunning = false
    private var didInstallSystemListeners = false
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var procID: AudioDeviceIOProcID?
    private var renderer: Renderer?
    private var retiredRenderer: Renderer?
    private var outputID = CA.unknown
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var pendingRebuild: DispatchWorkItem?
    private var recentRebuilds: [Date] = []
    private var wakeObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer?
    private var lastCallbackCount: UInt64 = 0
    private var stalledChecks = 0
    private var stallRestarts = 0
    private var soundFlowing = false
    private var reportedStall = false
    private var deviceName = ""

    // MARK: - Called from the main thread

    func setKnobs(volume: Double, balance: Double, bass: Double, mid: Double, treble: Double) {
        let v = shared.values
        v[SharedParams.volume] = Float(volume)
        v[SharedParams.balance] = Float(balance)
        v[SharedParams.bass] = Float(bass)
        v[SharedParams.mid] = Float(mid)
        v[SharedParams.treble] = Float(treble)
    }

    /// Recent peak of the incoming system audio (0 = silence). Drives the little activity dot.
    var level: Float { shared.values[SharedParams.level] }

    func start() {
        queue.async {
            guard !self.wantsRunning else { return }
            self.wantsRunning = true
            let leftovers = CA.destroyLeftoverAggregates(uidPrefix: Self.routeUIDPrefix)
            if leftovers > 0 { Diagnostics.log("Removed \(leftovers) leftover audio route(s)") }
            self.installSystemListeners()
            self.startHealthChecks()
            self.rebuild(reason: "launch")
        }
    }

    /// Synchronously removes the tap so system audio is never left muted.
    func shutdown() {
        queue.sync {
            wantsRunning = false
            pendingRebuild?.cancel()
            teardown()
        }
    }

    // MARK: - Route lifecycle (engine queue only)

    private func rebuild(reason: String) {
        pendingRebuild = nil
        teardown()
        guard wantsRunning else { return }

        // Safety valve: never spin in a restart loop.
        let now = Date()
        recentRebuilds = recentRebuilds.filter { now.timeIntervalSince($0) < 20 } + [now]
        guard recentRebuilds.count <= 8 else {
            Diagnostics.log("Too many restarts in a row; pausing")
            onStatus?(.problem("Audio kept restarting, so MiniEQ paused. Quit and reopen it to try again."))
            return
        }

        Diagnostics.log("Building audio route (\(reason))")
        do {
            let name = try build()
            onStatus?(.running(device: name))
        } catch {
            teardown()
            Diagnostics.log("Audio route failed: \(error.localizedDescription)")
            onStatus?(.problem(error.localizedDescription))
        }
    }

    private func build() throws -> String {
        guard let output = CA.defaultOutputDevice() else {
            throw EngineError("No sound output device is selected.")
        }
        guard let outputUID = CA.deviceUID(output) else {
            throw EngineError("Couldn't read the current output device.")
        }
        let name = CA.deviceName(output) ?? "Output"
        let transport = CA.transportType(output)
        if transport == kAudioDeviceTransportTypeAggregate {
            throw EngineError("“\(name)” is a multi-output device. Pick a regular output in Sound settings.")
        }
        let me = try ownProcessObject()

        // 1. Tap everything every app plays, except MiniEQ itself (no feedback loop).
        //    .mutedWhenTapped silences the original sound only while we're reading the tap,
        //    so whenever MiniEQ stops, audio goes straight to the speakers again.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        tapDescription.uuid = UUID()
        tapDescription.name = "MiniEQ"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped
        var tap = CA.unknown
        try check(AudioHardwareCreateProcessTap(tapDescription, &tap), "start capturing system audio")
        tapID = tap
        CrashGuard.tap = tap

        // 2. Private aggregate device: the real output device (also the clock) + the tap as input.
        //    Tap drift compensation stays off for Bluetooth, where it causes periodic crackles.
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MiniEQ",
            kAudioAggregateDeviceUIDKey: Self.routeUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: false],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: !isBluetooth],
            ],
        ]
        var aggregate = CA.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
                  "create the audio route")
        aggregateID = aggregate
        CrashGuard.aggregate = aggregate
        CA.waitUntilAlive(aggregate)

        // 3. Work out the sample rate and where left/right live on the output device.
        let sampleRate = CA.nominalSampleRate(aggregate) ?? CA.nominalSampleRate(output) ?? 48_000
        let outputLayout = CA.channelsPerStream(aggregate, scope: kAudioObjectPropertyScopeOutput)
        var inputLayout = CA.channelsPerStream(aggregate, scope: kAudioObjectPropertyScopeInput)
        for _ in 0..<10 where inputLayout.isEmpty {     // the tap's stream can take a moment to appear
            usleep(50_000)
            inputLayout = CA.channelsPerStream(aggregate, scope: kAudioObjectPropertyScopeInput)
        }
        let tapFormat = CA.tapFormat(tap)
        guard outputLayout.reduce(0, +) > 0 else {
            throw EngineError("“\(name)” has no output channels.")
        }
        guard !inputLayout.isEmpty else {
            throw EngineError("The system audio tap didn't connect.")
        }
        let stereo = CA.preferredStereoChannels(output)
        let left = locateChannel(stereo.0, in: outputLayout) ?? locateChannel(1, in: outputLayout) ?? (0, 0)
        let right = locateChannel(stereo.1, in: outputLayout) ?? locateChannel(2, in: outputLayout) ?? left

        // 4. Start processing.
        let newRenderer = Renderer(shared: shared, sampleRate: sampleRate, left: left, right: right)
        var createdProc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(aggregate, miniEQIOProc,
                                            Unmanaged.passUnretained(newRenderer).toOpaque(), &createdProc),
                  "set up audio processing")
        guard let proc = createdProc else { throw EngineError("Couldn't set up audio processing.") }
        procID = proc
        renderer = newRenderer
        CA.useOnlyLastInputStream(aggregate, proc: proc, streamCount: inputLayout.count)
        try check(AudioDeviceStart(aggregate, proc), "start audio processing")

        outputID = output
        deviceName = name
        reportedStall = false
        addDeviceListeners(output: output, aggregate: aggregate)
        var summary = "Routing via “\(name)” at \(Int(sampleRate)) Hz, transport \(fourCC(transport)), "
        summary += "output streams \(outputLayout), input streams \(inputLayout), "
        summary += "L=\(left.buffer):\(left.channel) R=\(right.buffer):\(right.channel), "
        let tapRate = Int(tapFormat?.mSampleRate ?? 0)
        let tapChannels = tapFormat?.mChannelsPerFrame ?? 0
        summary += "tap \(tapRate) Hz x \(tapChannels) ch, tap drift compensation \(!isBluetooth)"
        Diagnostics.log(summary)
        return name
    }

    private func teardown() {
        removeDeviceListeners()
        if aggregateID != CA.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != CA.unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        CrashGuard.aggregate = CA.unknown
        CrashGuard.tap = CA.unknown
        procID = nil
        aggregateID = CA.unknown
        tapID = CA.unknown
        outputID = CA.unknown
        retiredRenderer = renderer   // released on the next rebuild, well after the IOProc is gone
        renderer = nil
    }

    private func ownProcessObject() throws -> AudioObjectID {
        for _ in 0..<20 {
            if let object = CA.processObject(for: getpid()) { return object }
            usleep(50_000)
        }
        throw EngineError("Couldn't register MiniEQ with the audio system.")
    }

    // MARK: - Health checks (every 2 s)

    private func startHealthChecks() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealth() {
        let callbacks = shared.callbackCount.pointee
        defer { lastCallbackCount = callbacks }
        guard wantsRunning, renderer != nil else { stalledChecks = 0; return }

        // If Core Audio stops calling us while we should be running, rebuild the route once.
        if callbacks == lastCallbackCount {
            stalledChecks += 1
            if stalledChecks == 2 {
                if stallRestarts < 2 {
                    stallRestarts += 1
                    Diagnostics.log("Audio callbacks stopped; rebuilding the route")
                    scheduleRebuild("audio stalled", delay: 0.1)
                } else if !reportedStall {
                    reportedStall = true
                    Diagnostics.log("Audio callbacks still stopped after restarts; waiting for a device change")
                    onStatus?(.problem("The output device stopped accepting audio. Try picking it again in Sound settings."))
                }
            }
        } else {
            stalledChecks = 0
            stallRestarts = 0
            if reportedStall {
                reportedStall = false
                onStatus?(.running(device: deviceName))
            }
        }

        let flowing = shared.values[SharedParams.level] > 0.0005
        if flowing != soundFlowing {
            soundFlowing = flowing
            let peak = String(format: "%.3f", shared.values[SharedParams.level])
            Diagnostics.log(flowing ? "Sound is flowing through MiniEQ (peak \(peak), \(callbacks) callbacks)"
                                    : "Silence (nothing playing, \(callbacks) callbacks)")
        }
    }

    // MARK: - Reacting to device changes

    private func scheduleRebuild(_ reason: String, delay: TimeInterval = 0.35) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason: reason) }
        pendingRebuild = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func installSystemListeners() {
        guard !didInstallSystemListeners else { return }
        didInstallSystemListeners = true
        CA.useOwnNotificationThread()
        let context = Unmanaged.passUnretained(self).toOpaque()
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = CA.address(selector)
            AudioObjectAddPropertyListener(CA.system, &addr, engineListener, context)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.scheduleRebuild("woke from sleep", delay: 1.5) }
        }
    }

    private func addDeviceListeners(output: AudioObjectID, aggregate: AudioObjectID) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let wanted: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (output, kAudioDevicePropertyDeviceIsAlive),
            (output, kAudioDevicePropertyNominalSampleRate),
            (aggregate, kAudioDevicePropertyNominalSampleRate),
        ]
        for (object, selector) in wanted {
            var addr = CA.address(selector)
            if AudioObjectAddPropertyListener(object, &addr, engineListener, context) == noErr {
                deviceListeners.append((object, addr))
            }
        }
    }

    private func removeDeviceListeners() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (object, address) in deviceListeners {
            var addr = address
            AudioObjectRemovePropertyListener(object, &addr, engineListener, context)
        }
        deviceListeners.removeAll()
    }

    /// Runs on Core Audio's notification thread; hops onto the engine queue.
    fileprivate func propertiesChanged(_ object: AudioObjectID, _ selectors: [AudioObjectPropertySelector]) {
        queue.async {
            guard self.wantsRunning else { return }
            for selector in selectors {
                switch selector {
                case kAudioHardwarePropertyDefaultOutputDevice:
                    if CA.defaultOutputDevice() != self.outputID || self.aggregateID == CA.unknown {
                        self.scheduleRebuild("output device changed")
                    }
                case kAudioHardwarePropertyDevices:
                    if self.outputID != CA.unknown && !CA.isAlive(self.outputID) {
                        self.scheduleRebuild("output device went away")
                    }
                case kAudioDevicePropertyDeviceIsAlive:
                    if !CA.isAlive(object) {
                        self.scheduleRebuild("output device stopped")
                    }
                case kAudioDevicePropertyNominalSampleRate:
                    if let rate = CA.nominalSampleRate(self.aggregateID),
                       let current = self.renderer?.sampleRate, abs(rate - current) > 0.5 {
                        self.scheduleRebuild("sample rate changed to \(Int(rate)) Hz")
                    }
                default:
                    break
                }
            }
        }
    }
}

private func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(value)
}

private func engineListener(_ object: AudioObjectID, _ count: UInt32,
                            _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                            _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return noErr }
    let engine = Unmanaged<AudioEngine>.fromOpaque(context).takeUnretainedValue()
    var selectors: [AudioObjectPropertySelector] = []
    for i in 0..<Int(count) { selectors.append(addresses[i].mSelector) }
    engine.propertiesChanged(object, selectors)
    return noErr
}

// MARK: - Crash safety

/// If MiniEQ ever crashes, remove the tap on the way down so system sound isn't left muted.
/// (Leftovers from a hard kill are also cleaned up the next time MiniEQ starts.)
enum CrashGuard {
    static var tap = CA.unknown
    static var aggregate = CA.unknown

    static func install() {
        tap = CA.unknown        // touch the statics now; they're lazily initialized
        aggregate = CA.unknown
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashCleanup)
        }
    }
}

private func crashCleanup(_ sig: Int32) {
    signal(sig, SIG_DFL)
    if CrashGuard.aggregate != CA.unknown { AudioHardwareDestroyAggregateDevice(CrashGuard.aggregate) }
    if CrashGuard.tap != CA.unknown { AudioHardwareDestroyProcessTap(CrashGuard.tap) }
    raise(sig)
}
