//
//  RuntimeVersionOrdering.swift
//  DSH Studio
//

import Foundation

/// Orders Runtime and Harness version strings for comparison and sorting.
///
/// A Runtime version **is** the Harness version it contains (`0.2.0-rc.2`), so both
/// sides of a comparison are semantic versions and are ordered as such: core first,
/// then prerelease identifiers, with a released version above its own prereleases.
/// The `-ver<n>` build counter this project used before that rule was settled is
/// gone from the pipeline — every release it ever named has been unpublished — so it
/// carries no meaning here either. Anything that is not a semantic version falls back
/// to numeric-then-lexical component ordering.
public enum RuntimeVersionOrdering {
    /// Compares two version strings.
    ///
    /// A recognizable version always sorts after a string that is not one, so a
    /// published Runtime outranks something unrecognized.
    ///
    /// - Parameters:
    ///   - lhs: Left version string.
    ///   - rhs: Right version string.
    /// - Returns: The ordering of `lhs` relative to `rhs`.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftIsVersion = isRuntimeVersion(lhs)
        let rightIsVersion = isRuntimeVersion(rhs)
        if leftIsVersion, rightIsVersion {
            return compareHarnessVersions(lhs, rhs)
        }
        if leftIsVersion {
            return .orderedDescending
        }
        if rightIsVersion {
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
                return compareIdentifiers(l, r)
            }
        }
        return .orderedSame
    }

    private static func components(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Whether a string is a Runtime version.
    ///
    /// The shape is the one the Runtime repository publishes: `major.minor.patch` with
    /// an optional prerelease, and no build metadata, because a Runtime's identity is
    /// the Harness version and nothing is appended to it.
    ///
    /// - Parameter value: Version string being compared.
    /// - Returns: `true` when the string is a Runtime version.
    private static func isRuntimeVersion(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$"#,
            options: .regularExpression
        ) != nil
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
                return compareIdentifiers(l, r)
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
            return compareIdentifiers(left, right)
        }
        return .orderedSame
    }

    /// Compares two version identifiers without consulting the user's locale.
    ///
    /// The Runtime publication pipeline replicates this ordering in
    /// `check-catalog-precedent.sh` so it can never disagree with the client about
    /// which Runtime is newer. A locale-aware comparison would break that promise:
    /// the same two versions would order differently on different Macs, and the
    /// pipeline could publish a version a client reads as a downgrade.
    ///
    /// - Parameters:
    ///   - lhs: Left identifier.
    ///   - rhs: Right identifier.
    /// - Returns: The ordering of `lhs` relative to `rhs`.
    private static func compareIdentifiers(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        if let left = Int(lhs), let right = Int(rhs) {
            return left < right ? .orderedAscending : .orderedDescending
        }
        // A numeric identifier ranks below an alphanumeric one, the same rule the
        // semantic-versioning grammar uses for prerelease identifiers.
        if Int(lhs) != nil { return .orderedAscending }
        if Int(rhs) != nil { return .orderedDescending }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
