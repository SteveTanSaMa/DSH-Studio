//
//  RuntimeCatalogTrust.swift
//  DSH Studio
//

import Foundation

/// Trust anchor for the signed Runtime catalog.
///
/// The public key ships in the app's Info.plist instead of being fetched, so a
/// compromised catalog host cannot replace the key that verifies it.
public enum RuntimeCatalogTrust {
    /// Info.plist key holding the base64-encoded Ed25519 public key.
    public static let publicKeyInfoPlistKey = "RuntimeCatalogPublicKey"
    /// Key identifier the signed catalog must declare.
    public static let keyID = "runtime-catalog-v1"

    /// Reads the catalog public key from the app's Info.plist.
    ///
    /// An unresolved build setting is rejected as well, so a misconfigured build
    /// fails verification instead of trusting a placeholder value.
    ///
    /// - Parameter bundle: Bundle whose Info.plist is read.
    /// - Returns: The decoded key bytes, or `nil` when the key is absent or unusable.
    public static func publicKeyData(bundle: Bundle = .main) -> Data? {
        guard let value = bundle.object(forInfoDictionaryKey: publicKeyInfoPlistKey) as? String else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.hasPrefix("$(") else { return nil }
        return Data(base64Encoded: normalized)
    }
}
