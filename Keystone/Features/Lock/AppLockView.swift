import SwiftUI
import ComposableArchitecture
import Dependencies

/// Full-window biometric gate shown when `AppFeature.State.appLockUnlocked`
/// is `false`. Mounts above every other AppView overlay (palette, capture,
/// lookup) so a deep-link or stale state can never sneak past the lock.
///
/// The icon (`touchid` / `faceid`) and copy ("Touch ID" / "Face ID")
/// derive from `BiometricAuthClient.kind()`. On hardware without
/// biometrics it falls through to the device password via
/// `LAPolicy.deviceOwnerAuthentication`; the icon switches to a key.
struct AppLockView: View {
    @Bindable var store: StoreOf<AppFeature>

    @Dependency(\.biometricAuthClient) private var authClient
    @State private var kind: BiometricKind = .none

    var body: some View {
        ZStack {
            KstColor.paper0
                .ignoresSafeArea()

            VStack(spacing: 28) {
                KeystoneLogo(size: 56, radius: 14)

                VStack(spacing: 6) {
                    Text("Keystone is locked")
                        .font(.kstDisplay(size: 26, weight: .semibold))
                        .foregroundStyle(KstColor.ink0)
                    Text("Authenticate to continue")
                        .font(.kstText(size: 14))
                        .foregroundStyle(KstColor.ink2)
                }

                Button {
                    store.send(.unlockAppRequested)
                } label: {
                    HStack(spacing: 10) {
                        if store.authInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: kind.sfSymbol)
                                .font(.system(size: 16, weight: .medium))
                        }
                        Text(buttonTitle)
                            .font(.kstText(size: 14, weight: .semibold))
                    }
                    .frame(minWidth: 220)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(store.authInFlight)
            }
            .padding(36)
        }
        .task {
            // Resolve biometric flavor once; cheap call.
            kind = authClient.kind()
        }
        // Block clicks/keystrokes from reaching the underlying UI even if
        // a stray hit-test slipped through. The ZStack background + this
        // gesture keep the lock screen modal in practice.
        .contentShape(Rectangle())
        .onTapGesture { /* swallow */ }
    }

    private var buttonTitle: String {
        if store.authInFlight { return "Authenticating…" }
        switch kind {
        case .none:     return "Authenticate"
        case .touchID:  return "Unlock with Touch ID"
        case .faceID:   return "Unlock with Face ID"
        case .opticID:  return "Unlock with Optic ID"
        }
    }
}
