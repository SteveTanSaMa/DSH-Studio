//
//  RuntimePackageLockValidator.swift
//  DSH Studio
//

import Foundation

/// Validates the npm lockfile before npm is allowed to install dependencies.
public enum RuntimePackageLockValidator {
    public static func validate(
        data: Data,
        expectedHarnessVersion: String = RuntimeRelease.harnessVersion,
        expectedHarnessIntegrity: String = RuntimeRelease.harnessPackageIntegrity,
        expectedPnpmVersion: String = RuntimeRelease.pnpmVersion,
        expectedPnpmIntegrity: String = RuntimeRelease.pnpmPackageIntegrity,
        expectedRegistryHost: String = RuntimeRelease.registryHost
    ) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lockfileVersion = root["lockfileVersion"] as? Int,
              lockfileVersion == 3,
              let packages = root["packages"] as? [String: Any],
              let packageRoot = packages[""] as? [String: Any],
              let dependencies = packageRoot["dependencies"] as? [String: Any],
              dependencies[RuntimeLocator.dshPackageName] as? String == expectedHarnessVersion,
              dependencies["pnpm"] as? String == expectedPnpmVersion else {
            throw RuntimeProvisioningError.invalidPackageLock("根依赖或 lockfileVersion 无效")
        }

        guard let harnessPackage = packages["node_modules/\(RuntimeLocator.dshPackageName)"] as? [String: Any],
              harnessPackage["version"] as? String == expectedHarnessVersion,
              harnessPackage["integrity"] as? String == expectedHarnessIntegrity else {
            throw RuntimeProvisioningError.invalidPackageLock("Harness 包版本或 integrity 无效")
        }

        guard let pnpmPackage = packages["node_modules/pnpm"] as? [String: Any],
              pnpmPackage["version"] as? String == expectedPnpmVersion,
              pnpmPackage["integrity"] as? String == expectedPnpmIntegrity else {
            throw RuntimeProvisioningError.invalidPackageLock("pnpm 包版本或 integrity 无效")
        }

        for (path, rawPackage) in packages where !path.isEmpty {
            guard let package = rawPackage as? [String: Any],
                  let integrity = package["integrity"] as? String,
                  !integrity.isEmpty else {
                throw RuntimeProvisioningError.invalidPackageLock("缺少 \(path) 的 integrity")
            }
            guard let resolved = package["resolved"] as? String,
                  let components = URLComponents(string: resolved),
                  components.scheme == "https",
                  components.host == expectedRegistryHost,
                  components.user == nil,
                  components.password == nil,
                  components.port == nil else {
                throw RuntimeProvisioningError.invalidPackageLock("\(path) 不是官方 npm registry tarball")
            }
        }
    }
}
