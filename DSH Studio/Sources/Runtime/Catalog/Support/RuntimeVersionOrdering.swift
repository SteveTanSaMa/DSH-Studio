//
//  RuntimeVersionOrdering.swift
//  DSH Studio
//

import Foundation

public enum RuntimeVersionOrdering {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = standardizedRuntimeVersion(lhs),
           let right = standardizedRuntimeVersion(rhs) {
            let harnessResult = compareHarnessVersions(left.harness, right.harness)
            if harnessResult != .orderedSame {
                return harnessResult
            }
            return left.revision == right.revision
                ? .orderedSame
                : (left.revision < right.revision ? .orderedAscending : .orderedDescending)
        }
        if standardizedRuntimeVersion(lhs) != nil {
            return .orderedDescending
        }
        if standardizedRuntimeVersion(rhs) != nil {
            return .orderedAscending
        }

        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : ""
            let r = index < right.count ? right[index] : ""
            if let ln = Int(l), let rn = Int(r), ln != rn {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if l != r {
                return l.localizedStandardCompare(r)
            }
        }
        return .orderedSame
    }

    private static func components(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func standardizedRuntimeVersion(_ value: String) -> (harness: String, revision: Int)? {
        guard let range = value.range(of: #"-ver[1-9][0-9]*$"#, options: .regularExpression),
              let revision = Int(value[range].dropFirst(4)) else {
            return nil
        }
        let harness = String(value[..<range.lowerBound])
        guard !harness.isEmpty else { return nil }
        return (harness, revision)
    }

    private static func compareHarnessVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parseHarnessVersion(lhs)
        let right = parseHarnessVersion(rhs)
        guard let left, let right else {
            return compareComponents(components(lhs), components(rhs))
        }

        for (l, r) in zip(left.core, right.core) where l != r {
            return l < r ? .orderedAscending : .orderedDescending
        }
        if left.core.count != right.core.count {
            return left.core.count < right.core.count ? .orderedAscending : .orderedDescending
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case let (left?, right?):
            return comparePrerelease(left, right)
        }
    }

    private static func compareComponents(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : ""
            let r = index < rhs.count ? rhs[index] : ""
            if let ln = Int(l), let rn = Int(r), ln != rn {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if l != r {
                return l.localizedStandardCompare(r)
            }
        }
        return .orderedSame
    }

    private static func parseHarnessVersion(_ value: String) -> (core: [Int], prerelease: [String]?)? {
        let parts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
        let withoutBuild = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let coreParts = withoutBuild[0].split(separator: ".", omittingEmptySubsequences: false)
        let core = coreParts.compactMap { Int($0) }
        guard coreParts.count == 3, core.count == 3 else {
            return nil
        }
        let prerelease = withoutBuild.count == 2
            ? withoutBuild[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : nil
        return (core, prerelease)
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            guard index < lhs.count else { return .orderedAscending }
            guard index < rhs.count else { return .orderedDescending }
            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }
            if let ln = Int(left), let rn = Int(right) {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if Int(left) != nil { return .orderedAscending }
            if Int(right) != nil { return .orderedDescending }
            return left.localizedStandardCompare(right)
        }
        return .orderedSame
    }
}
