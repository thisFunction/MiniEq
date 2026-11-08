import Foundation

/// The "System Audio Recording" permission.
///
/// macOS has no public API to check or request it ahead of time, so this uses the private TCC
/// framework (the same approach as the open-source AudioCap project). If that ever stops
/// working, MiniEQ simply starts, and macOS asks for permission the first time audio flows.
enum CapturePermission {
    enum State { case authorized, denied, notDetermined, unavailable }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func current() -> State {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unavailable }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt. Returns false if the request couldn't be made at all.
    @discardableResult
    static func request(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(symbol, to: RequestFn.self)
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        return true
    }
}
