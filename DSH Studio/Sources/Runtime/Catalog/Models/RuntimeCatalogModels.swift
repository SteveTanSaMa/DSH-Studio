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
    /// The envelope schema this app accepts; other versions fail verification.
    public static let currentSchemaVersion = 1

    /// Schema version of the signed envelope.
    public let schemaVersion: Int
    /// Identifier of the signing key, checked against the expected key.
    public let keyID: String
    /// Base64-encoded catalog bytes, verified exactly as published.
    public let payload: String
    /// Base64-encoded Ed25519 signature over ``payload``.
    public let signature: String

    /// Creates a signed envelope.
    ///
    /// - Parameters:
    ///   - schemaVersion: Envelope schema; defaults to ``currentSchemaVersion``.
    ///   - keyID: Identifier of the signing key.
    ///   - payload: Base64-encoded catalog bytes.
    ///   - signature: Base64-encoded signature over the payload.
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

    /// Verifies the signature and decodes the enclosed catalog.
    ///
    /// The signature is checked over the payload bytes as published, so JSON
    /// whitespace and key order cannot affect the result.
    ///
    /// - Parameters:
    ///   - publicKeyData: Raw Ed25519 public key.
    ///   - expectedKeyID: Key identifier the envelope must carry, when known.
    /// - Returns: The verified catalog.
    /// - Throws: ``RuntimeCatalogError`` when the envelope is malformed, the key does
    ///   not match, the signature is invalid, or the payload is not a valid catalog.
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
    /// Signs a catalog for tests and local tooling.
    ///
    /// - Parameters:
    ///   - catalog: Catalog to sign.
    ///   - privateKey: Ed25519 private key.
    ///   - keyID: Identifier recorded in the envelope.
    /// - Returns: A signed envelope containing the pretty-printed catalog.
    /// - Throws: An error when the catalog cannot be encoded or signed.
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

/// Failures raised while fetching and verifying a Runtime catalog.
public enum RuntimeCatalogError: Error, Equatable, LocalizedError, Sendable {
    /// The signed envelope is missing fields or has an unexpected schema.
    case invalidEnvelope
    /// The embedded public key could not be read as an Ed25519 key.
    case invalidPublicKey
    /// The signature does not match the payload.
    case signatureInvalid
    /// The verified payload is not a decodable catalog.
    case invalidCatalog
    /// No catalog source produced a usable release.
    case unavailable
    /// The catalog download failed; carries the transport detail.
    case downloadFailed(String)

    /// A localized, user-facing description of the failure.
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
