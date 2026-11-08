import Foundation
import CoreAudio
import AudioToolbox

/// Small, typed helpers around the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value (numbers, IDs, structs).
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        return err == noErr ? value : nil
    }

    /// Reads a CFString property (the HAL hands back a +1 reference).
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let result = value else { return nil }
        return result.takeRetainedValue() as String
    }

    // MARK: System

    /// Deliver HAL notifications on Core Audio's own thread instead of the main run loop.
    static func useOwnNotificationThread() {
        var noRunLoop: UnsafeMutableRawPointer? = nil   // a NULL CFRunLoopRef
        var addr = address(kAudioHardwarePropertyRunLoop)
        _ = AudioObjectSetPropertyData(system, &addr, 0, nil,
                                       UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size), &noRunLoop)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown), id != unknown else { return nil }
        return id
    }

    static func allDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// The HAL's object for a process (needed to exclude ourselves from the system tap).
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return (err == noErr && object != unknown) ? object : nil
    }

    /// The format of the audio the tap delivers (normally 2-channel 32-bit float).
    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    }

    // MARK: Devices

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        get(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (get(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) ?? 0) != 0
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        guard let rate = get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)), rate > 0 else { return nil }
        return rate
    }

    /// Channels in each stream (one entry per AudioBuffer the IOProc will see).
    static func channelsPerStream(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// The device's left/right channel numbers (1-based), usually (1, 2).
    static func preferredStereoChannels(_ device: AudioObjectID) -> (UInt32, UInt32) {
        var addr = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var channels: (UInt32, UInt32) = (1, 2)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &channels)
        guard err == noErr, channels.0 > 0, channels.1 > 0 else { return (1, 2) }
        return channels
    }

    /// Wait (briefly) for a freshly created device to come alive.
    static func waitUntilAlive(_ device: AudioObjectID, timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !isAlive(device) && Date() < deadline { usleep(10_000) }
    }

    /// Tell the HAL our IOProc only reads the *last* input stream (the system-audio tap).
    /// Without this, an output device that also has a microphone (USB headsets, AirPods)
    /// would get its mic switched on — which can trigger a mic prompt or drop AirPods
    /// into low-quality "call" mode.
    static func useOnlyLastInputStream(_ device: AudioObjectID, proc: AudioDeviceIOProcID, streamCount: Int) {
        guard streamCount > 1 else { return }
        // struct AudioHardwareIOProcStreamUsage { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
        let header = pointerSize + MemoryLayout<UInt32>.size
        let total = header + streamCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streamCount), toByteOffset: pointerSize, as: UInt32.self)
        for i in 0..<streamCount {
            raw.storeBytes(of: UInt32(i == streamCount - 1 ? 1 : 0), toByteOffset: header + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(total), raw)
    }

    /// Removes routing devices left behind if MiniEQ was ever killed without cleaning up
    /// (a leftover one could keep system sound muted).
    @discardableResult
    static func destroyLeftoverAggregates(uidPrefix: String) -> Int {
        var count = 0
        for device in allDevices() where transportType(device) == kAudioDeviceTransportTypeAggregate {
            if let uid = deviceUID(device), uid.hasPrefix(uidPrefix),
               AudioHardwareDestroyAggregateDevice(device) == noErr {
                count += 1
            }
        }
        return count
    }
}

/// Maps a 1-based device channel number to (buffer index, channel within that buffer).
func locateChannel(_ channel: UInt32, in layout: [Int]) -> (buffer: Int, channel: Int)? {
    guard channel >= 1 else { return nil }
    var remaining = Int(channel) - 1
    for (index, channels) in layout.enumerated() {
        if remaining < channels { return (index, remaining) }
        remaining -= channels
    }
    return nil
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw EngineError("Couldn't \(what) (error \(status)).") }
}
