import CryptoKit
import KeyAgent

/// What the device asks with before a key signs: "Touch ID" on the Mac, "Face ID" on iOS.
enum DeviceAuthentication {
    #if os(macOS)
    static let name = "Touch ID"
    static let device = "Mac"
    #else
    static let name = "Face ID"
    static let device = "device"
    #endif
}

extension SigningPolicy {
    var title: String {
        switch self {
        case .always: "Never ask"
        case .oncePerSession: "Once per session"
        case .everySignature: "Every connection"
        }
    }

    var explanation: String {
        let auth = DeviceAuthentication.name
        #if os(macOS)
        switch self {
        case .always: return "Signs without \(auth) when ssh started by AeroOps asks. Any other program always needs \(auth)."
        case .oncePerSession: return "\(auth) the first time the key signs, then not again until the Mac sleeps, locks or AeroOps quits."
        case .everySignature: return "\(auth) for every new SSH connection."
        }
        #else
        switch self {
        case .always: return "Signs in without asking. Only AeroOps can use the key."
        case .oncePerSession: return "\(auth) or the passcode the first time the key signs, then not again until AeroOps quits."
        case .everySignature: return "\(auth) or the passcode for every new SSH connection."
        }
        #endif
    }
}

extension KeyGenerationType {
    /// The type offered first: Secure Enclave when this device has one, else Ed25519.
    static var recommended: KeyGenerationType {
        SecureEnclave.isAvailable ? .secureEnclaveP256 : .ed25519
    }

    var title: String {
        switch self {
        case .ed25519: "Ed25519"
        case .secureEnclaveP256: "Secure Enclave (ECDSA P-256)"
        }
    }

    var explanation: String {
        let device = DeviceAuthentication.device
        return switch self {
        case .ed25519:
            "Stored in your Keychain. Works with every OpenSSH server from 6.5 on."
        case .secureEnclaveP256:
            SecureEnclave.isAvailable
                ? "Created inside this \(device)’s Secure Enclave and can never leave it. Back it up by adding a second key to your servers."
                : "This \(device) has no Secure Enclave."
        }
    }
}
