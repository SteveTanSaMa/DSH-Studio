//
//  RuntimeCatalogModels.swift
//  DSH Studio
//

import CryptoKit
import Foundation

/// A signed wrapper around the catalog payload published by DSH Studio.
///
/// The payload is signed as raw bytes rather than re-encoded after decoding.
/// This keeps verification independent of JSON whitespace and key ordering.
public struct RuntimeSignedCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let keyID: String
    public let payload: String
    public let signature: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        keyID: String,
        payload: String,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }

    public func verifiedCatalog(
        publicKeyData: Data,
        expectedKeyID: String? = nil
    ) throws -> RuntimeReleaseCatalog {
        guard schemaVersion == Self.currentSchemaVersion,
              !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedKeyID == nil || keyID == expectedKeyID,
              let payloadData = Data(base64Encoded: payload),
              let signatureData = Data(base64Encoded: signature) else {
            throw RuntimeCatalogError.invalidEnvelope
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw RuntimeCatalogError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw RuntimeCatalogError.signatureInvalid
        }
        do {
            return try RuntimeReleaseCatalog.decode(payloadData)
        } catch {
            throw RuntimeCatalogError.invalidCatalog
        }
    }

    #if DEBUG
    public static func signed(
        catalog: RuntimeReleaseCatalog,
        using privateKey: Curve25519.Signing.PrivateKey,
        keyID: String
    ) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payloadData = try encoder.encode(catalog)
        let signatureData = try privateKey.signature(for: payloadData)
        return Self(
            keyID: keyID,
            payload: payloadData.base64EncodedString(),
            signature: signatureData.base64EncodedString()
        )
    }
    #endif
}

public enum RuntimeCatalogError: Error, Equatable, LocalizedError, Sendable {
    case invalidEnvelope
    case invalidPublicKey
    case signatureInvalid
    case invalidCatalog
    case unavailable
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Runtime catalog 签名封装无效"
        case .invalidPublicKey:
            return "Runtime catalog 公钥无效"
        case .signatureInvalid:
            return "Runtime catalog 签名校验失败"
        case .invalidCatalog:
            return "Runtime catalog 内容无效"
        case .unavailable:
            return "没有可用的 Runtime catalog"
        case .downloadFailed(let detail):
            return "Runtime catalog 下载失败：\(detail)"
        }
    }
}
