//
//  RuntimeCatalogTrust.swift
//  DSH Studio
//

import Foundation

public enum RuntimeCatalogTrust {
    public static let publicKeyInfoPlistKey = "RuntimeCatalogPublicKey"
    public static let keyID = "runtime-catalog-v1"

    public static func publicKeyData(bundle: Bundle = .main) -> Data? {
        guard let value = bundle.object(forInfoDictionaryKey: publicKeyInfoPlistKey) as? String else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.hasPrefix("$(") else { return nil }
        return Data(base64Encoded: normalized)
    }
}
