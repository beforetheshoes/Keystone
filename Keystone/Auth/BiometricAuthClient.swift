import Foundation
import Dependencies
import DependenciesMacros
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// What hardware the device can use to authenticate. Drives the lock
/// screen's icon ("touchid" vs "faceid") and copy ("Touch ID" vs "Face
/// ID"). `.none` means biometrics aren't available — the live `evaluate`
/// path falls back to the device passcode / Mac account password via
/// `LAPolicy.deviceOwnerAuthentication`.
enum BiometricKind: String, Sendable, Equatable {
    case none, touchID, faceID, opticID

    var displayName: String {
        switch self {
        case .none:     return "Password"
        case .touchID:  return "Touch ID"
        case .faceID:   return "Face ID"
        case .opticID:  return "Optic ID"
        }
    }

    var sfSymbol: String {
        switch self {
        case .none:     return "key.fill"
        case .touchID:  return "touchid"
        case .faceID:   return "faceid"
        case .opticID:  return "opticid"
        }
    }
}

/// TCA dependency wrapping `LAContext`. Generic — does not know about
/// trips, records, or any domain object. Session unlock state lives in
/// `AppFeature.State`; this client just answers "what's available?" and
/// "did the user authenticate?".
///
/// Live value uses `LAPolicy.deviceOwnerAuthentication` so a Mac without
/// Touch ID still falls back to the user's account password — preserving
/// the lock guarantee on every macOS device, not just biometric-equipped
/// ones.
@DependencyClient
struct BiometricAuthClient: Sendable {
    /// True when the device can run a biometric or device-owner auth check.
    /// (`evaluatePolicy(deviceOwnerAuthentication, ...)` is essentially
    /// always available on macOS, so this returns true outside of unit
    /// tests, where the test value returns false unless overridden.)
    var canAuthenticate: @Sendable () -> Bool = { false }

    /// What flavor of biometrics the device supports, if any.
    /// `.none` is valid (e.g., a Mac mini without Touch ID) — auth still
    /// works via the password fallback; the lock view just renders a key
    /// icon instead of fingerprint/face.
    var kind: @Sendable () -> BiometricKind = { .none }

    /// Run a single auth challenge. The reason string is shown in the
    /// system biometric prompt. Returns true on success, false on cancel
    /// / fallback failure / hardware error. Never throws — callers should
    /// treat false as "user declined or auth failed" and re-show their
    /// lock UI rather than tell the user something went wrong.
    var authenticate: @Sendable (_ reason: String) async -> Bool = { _ in false }
}

extension BiometricAuthClient: DependencyKey {
    static let liveValue: BiometricAuthClient = {
        #if canImport(LocalAuthentication)
        return BiometricAuthClient(
            canAuthenticate: {
                let ctx = LAContext()
                var err: NSError?
                return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
            },
            kind: {
                let ctx = LAContext()
                var err: NSError?
                guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
                    return .none
                }
                switch ctx.biometryType {
                case .touchID:  return .touchID
                case .faceID:   return .faceID
                case .opticID:  return .opticID
                case .none:     return .none
                @unknown default: return .none
                }
            },
            authenticate: { reason in
                let ctx = LAContext()
                // Reuse the auth result for 10s within the same context so
                // the user isn't prompted twice when an unlock action
                // immediately drives a follow-up read.
                ctx.touchIDAuthenticationAllowableReuseDuration = 10
                do {
                    return try await ctx.evaluatePolicy(
                        .deviceOwnerAuthentication,
                        localizedReason: reason
                    )
                } catch {
                    return false
                }
            }
        )
        #else
        // Non-Apple platforms: no auth available. Lock UI should never
        // be reachable on these targets, but the dependency must
        // resolve.
        return BiometricAuthClient(
            canAuthenticate: { false },
            kind: { .none },
            authenticate: { _ in false }
        )
        #endif
    }()

    /// In tests, default to "biometrics available, succeed instantly" so
    /// app-lock-aware tests don't have to override unless they want to
    /// simulate failure.
    static let testValue = BiometricAuthClient(
        canAuthenticate: { true },
        kind: { .faceID },
        authenticate: { _ in true }
    )
}

extension DependencyValues {
    var biometricAuthClient: BiometricAuthClient {
        get { self[BiometricAuthClient.self] }
        set { self[BiometricAuthClient.self] = newValue }
    }
}
