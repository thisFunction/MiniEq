import Foundation
import CoreAudio

/// Knob values shared between the UI and Core Audio's real-time thread.
/// Each slot is one aligned 32-bit float, so a read never sees a half-written value
/// on Apple hardware. The UI writes the knob slots; the audio thread only reads them
/// (and writes the level meter + callback counter, which only the UI reads).
final class SharedParams {
    static let volume = 0, balance = 1, bass = 2, mid = 3, treble = 4, level = 5
    private static let slotCount = 8

    let values: UnsafeMutablePointer<Float>
    let callbackCount: UnsafeMutablePointer<UInt64>

    init() {
        let knobValues = UnsafeMutablePointer<Float>.allocate(capacity: SharedParams.slotCount)
        knobValues.initialize(repeating: 0, count: SharedParams.slotCount)
        knobValues[SharedParams.volume] = 1
        let counter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        counter.initialize(to: 0)
        values = knobValues
        callbackCount = counter
    }

    deinit {
        values.deinitialize(count: SharedParams.slotCount)
        values.deallocate()
        callbackCount.deinitialize(count: 1)
        callbackCount.deallocate()
    }
}

// MARK: - Tone controls

/// Where each knob acts. Tweak these to taste.
enum Tone {
    static let bassHz = 120.0      // low shelf
    static let midHz = 1_000.0     // bell
    static let midQ = 0.7          // wide bell (~2 octaves)
    static let trebleHz = 8_000.0  // high shelf
    static let maxDB = 12.0        // each tone knob goes ±12 dB

    // RBJ "Audio EQ Cookbook" biquads, normalized so a0 == 1. Shelves use slope S = 1.

    static func lowShelf(hz: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(hz, fs * 0.45) / fs
        let cw = cos(w0)
        let k = 2 * sqrt(a) * (sin(w0) / 2 * sqrt(2.0))   // 2·√A·α with S = 1
        let a0 = (a + 1) + (a - 1) * cw + k
        return BiquadCoefficients(
            b0: a * ((a + 1) - (a - 1) * cw + k) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * cw) / a0,
            b2: a * ((a + 1) - (a - 1) * cw - k) / a0,
            a1: -2 * ((a - 1) + (a + 1) * cw) / a0,
            a2: ((a + 1) + (a - 1) * cw - k) / a0)
    }

    static func highShelf(hz: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(hz, fs * 0.45) / fs
        let cw = cos(w0)
        let k = 2 * sqrt(a) * (sin(w0) / 2 * sqrt(2.0))
        let a0 = (a + 1) - (a - 1) * cw + k
        return BiquadCoefficients(
            b0: a * ((a + 1) + (a - 1) * cw + k) / a0,
            b1: -2 * a * ((a - 1) + (a + 1) * cw) / a0,
            b2: a * ((a + 1) + (a - 1) * cw - k) / a0,
            a1: 2 * ((a - 1) - (a + 1) * cw) / a0,
            a2: ((a + 1) - (a - 1) * cw - k) / a0)
    }

    static func bell(hz: Double, q: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(hz, fs * 0.45) / fs
        let cw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / a
        return BiquadCoefficients(
            b0: (1 + alpha * a) / a0,
            b1: -2 * cw / a0,
            b2: (1 - alpha * a) / a0,
            a1: -2 * cw / a0,
            a2: (1 - alpha / a) / a0)
    }
}

struct BiquadCoefficients {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// How much this filter boosts or cuts a given frequency, in dB (used by the tone curve).
    func magnitudeDB(at hz: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * hz / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numReal = b0 + b1 * c1 + b2 * c2
        let numImag = b1 * s1 + b2 * s2
        let denReal = 1 + a1 * c1 + a2 * c2
        let denImag = a1 * s1 + a2 * s2
        let ratio = (numReal * numReal + numImag * numImag) / (denReal * denReal + denImag * denImag)
        return 10 * log10(ratio)
    }
}

extension Tone {
    /// The three tone filters for a given knob setting — exactly what the audio thread uses.
    static func filters(bass: Double, mid: Double, treble: Double, sampleRate fs: Double) -> [BiquadCoefficients] {
        [lowShelf(hz: bassHz, gainDB: bass, sampleRate: fs),
         bell(hz: midHz, q: midQ, gainDB: mid, sampleRate: fs),
         highShelf(hz: trebleHz, gainDB: treble, sampleRate: fs)]
    }
}

/// One biquad for left + right. Direct Form I in Double precision: stable at low
/// frequencies and click-free when the coefficients change while audio is playing.
struct StereoBiquad {
    var c = BiquadCoefficients()
    private var lx1 = 0.0, lx2 = 0.0, ly1 = 0.0, ly2 = 0.0
    private var rx1 = 0.0, rx2 = 0.0, ry1 = 0.0, ry2 = 0.0

    @inline(__always)
    mutating func process(_ l: inout Double, _ r: inout Double) {
        var yl = c.b0 * l + c.b1 * lx1 + c.b2 * lx2 - c.a1 * ly1 - c.a2 * ly2
        var yr = c.b0 * r + c.b1 * rx1 + c.b2 * rx2 - c.a1 * ry1 - c.a2 * ry2
        if abs(yl) < 1e-20 { yl = 0 }   // stop decaying tails from turning into denormals
        if abs(yr) < 1e-20 { yr = 0 }
        lx2 = lx1; lx1 = l; ly2 = ly1; ly1 = yl
        rx2 = rx1; rx1 = r; ry2 = ry1; ry1 = yr
        l = yl
        r = yr
    }

    var isHealthy: Bool { ly1.isFinite && ly2.isFinite && ry1.isFinite && ry2.isFinite }

    mutating func reset() {
        lx1 = 0; lx2 = 0; ly1 = 0; ly2 = 0
        rx1 = 0; rx2 = 0; ry1 = 0; ry2 = 0
    }
}

/// Transparent below 0.95 (≈ -0.4 dBFS); above that it bends smoothly toward 1.0
/// instead of hard-clipping when bass/mid/treble boosts push peaks over full scale.
@inline(__always)
func softLimit(_ x: Float) -> Float {
    let threshold: Float = 0.95
    let magnitude = abs(x)
    if magnitude <= threshold { return x }
    guard magnitude.isFinite else { return 0 }
    let headroom = 1 - threshold
    let over = magnitude - threshold
    let y = threshold + headroom * (over / (over + headroom))
    return x < 0 ? -y : y
}

/// Volume knob position (0…1) → linear gain. Cubic "audio taper": 50 % ≈ -18 dB.
@inline(__always)
func volumeGain(_ knob: Float) -> Float {
    let v = min(max(knob, 0), 1)
    return v * v * v
}

/// Balance (-1 = left … +1 = right) → per-side gain. Center leaves both at full level;
/// turning toward one side fades the other side out.
@inline(__always)
func balanceGains(_ balance: Float) -> (left: Float, right: Float) {
    let b = min(max(balance, -1), 1)
    return (min(1, 1 - b), min(1, 1 + b))
}

// MARK: - Real-time renderer

/// Owns all state the audio thread touches. One instance per audio route; a new one is
/// made whenever the output device or sample rate changes.
final class Renderer {
    let sampleRate: Double
    private let shared: SharedParams          // keeps the shared memory alive
    private let knobs: UnsafeMutablePointer<Float>
    private let callbacks: UnsafeMutablePointer<UInt64>
    private let left: (buffer: Int, channel: Int)
    private let right: (buffer: Int, channel: Int)

    private var bass = StereoBiquad(), mid = StereoBiquad(), treble = StereoBiquad()
    private var bassDB: Double, midDB: Double, trebleDB: Double
    private var gainL: Float = 0, gainR: Float = 0   // start silent → ~15 ms fade-in, no pop
    private let gainSmoothing: Float

    init(shared: SharedParams, sampleRate: Double,
         left: (buffer: Int, channel: Int), right: (buffer: Int, channel: Int)) {
        let values = shared.values
        let startBass = Renderer.clampDB(values[SharedParams.bass])
        let startMid = Renderer.clampDB(values[SharedParams.mid])
        let startTreble = Renderer.clampDB(values[SharedParams.treble])
        self.shared = shared
        self.knobs = values
        self.callbacks = shared.callbackCount
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
        self.gainSmoothing = Float(1 - exp(-1 / (sampleRate * 0.015)))
        self.bassDB = startBass
        self.midDB = startMid
        self.trebleDB = startTreble
        bass.c = Tone.lowShelf(hz: Tone.bassHz, gainDB: startBass, sampleRate: sampleRate)
        mid.c = Tone.bell(hz: Tone.midHz, q: Tone.midQ, gainDB: startMid, sampleRate: sampleRate)
        treble.c = Tone.highShelf(hz: Tone.trebleHz, gainDB: startTreble, sampleRate: sampleRate)
    }

    private static func clampDB(_ value: Float) -> Double {
        let v = Double(value)
        return v.isFinite ? min(max(v, -Tone.maxDB), Tone.maxDB) : 0
    }

    /// Called on the real-time thread: no locks, no allocation, no Objective-C, no logging.
    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        callbacks.pointee &+= 1

        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // The system-audio tap is the last input stream of our private aggregate device.
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard ins.count > 0, left.buffer < outs.count, right.buffer < outs.count else { return }
        let tap = ins[ins.count - 1]
        let outL = outs[left.buffer]
        let outR = outs[right.buffer]
        guard let src = tap.mData?.assumingMemoryBound(to: Float.self),
              let dstL = outL.mData?.assumingMemoryBound(to: Float.self),
              let dstR = outR.mData?.assumingMemoryBound(to: Float.self) else { return }

        let inStride = max(1, Int(tap.mNumberChannels))
        let lStride = max(1, Int(outL.mNumberChannels))
        let rStride = max(1, Int(outR.mNumberChannels))
        guard left.channel < lStride, right.channel < rStride else { return }
        let sampleSize = MemoryLayout<Float>.size
        let frames = min(Int(tap.mDataByteSize) / (sampleSize * inStride),
                         Int(outL.mDataByteSize) / (sampleSize * lStride),
                         Int(outR.mDataByteSize) / (sampleSize * rStride))
        guard frames > 0 else { return }

        // Knob targets.
        let master = volumeGain(knobs[SharedParams.volume])
        let sides = balanceGains(knobs[SharedParams.balance])
        let targetL = master * sides.left
        let targetR = master * sides.right
        updateTone(frames: frames)

        // Work on local copies (fast, no exclusivity checks in the loop).
        var b = bass, m = mid, t = treble
        var gl = gainL, gr = gainR
        let k = gainSmoothing
        let secondInput = inStride > 1 ? 1 : 0
        let mono = left.buffer == right.buffer && left.channel == right.channel
        var peak: Float = 0

        for i in 0..<frames {
            let inL = src[i * inStride]
            let inR = src[i * inStride + secondInput]
            peak = max(peak, abs(inL), abs(inR))
            var l = Double(inL), r = Double(inR)
            b.process(&l, &r)
            m.process(&l, &r)
            t.process(&l, &r)
            gl += (targetL - gl) * k
            gr += (targetR - gr) * k
            let yl = Float(l) * gl
            let yr = Float(r) * gr
            if mono {
                dstL[i * lStride + left.channel] = softLimit(0.5 * (yl + yr))
            } else {
                dstL[i * lStride + left.channel] = softLimit(yl)
                dstR[i * rStride + right.channel] = softLimit(yr)
            }
        }

        if !(b.isHealthy && m.isHealthy && t.isHealthy) {
            b.reset(); m.reset(); t.reset()
        }
        bass = b; mid = m; treble = t
        gainL = gl; gainR = gr
        let previous = knobs[SharedParams.level]
        knobs[SharedParams.level] = peak.isFinite ? max(peak, previous * 0.85) : 0
    }

    /// Glide each tone knob toward its new setting (~40 ms) so turning a knob never clicks.
    @inline(__always)
    private func updateTone(frames: Int) {
        let k = 1 - exp(-Double(frames) / (sampleRate * 0.04))
        if Self.approach(&bassDB, Self.clampDB(knobs[SharedParams.bass]), k) {
            bass.c = Tone.lowShelf(hz: Tone.bassHz, gainDB: bassDB, sampleRate: sampleRate)
        }
        if Self.approach(&midDB, Self.clampDB(knobs[SharedParams.mid]), k) {
            mid.c = Tone.bell(hz: Tone.midHz, q: Tone.midQ, gainDB: midDB, sampleRate: sampleRate)
        }
        if Self.approach(&trebleDB, Self.clampDB(knobs[SharedParams.treble]), k) {
            treble.c = Tone.highShelf(hz: Tone.trebleHz, gainDB: trebleDB, sampleRate: sampleRate)
        }
    }

    @inline(__always)
    private static func approach(_ current: inout Double, _ target: Double, _ k: Double) -> Bool {
        if current == target { return false }
        var next = current + (target - current) * k
        if abs(target - next) < 0.01 { next = target }
        current = next
        return true
    }
}

/// The IOProc Core Audio calls on its real-time thread for every buffer of system audio.
let miniEQIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<Renderer>.fromOpaque(clientData).takeUnretainedValue().render(input, output)
    return noErr
}
