//
//  PluginCompatibility.swift
//  DSH Studio
//

import Foundation

/// Decides whether one Harness version satisfies the range a plugin declares.
///
/// Harness plugins publish their compatibility as a `peerDependencies` range over the
/// Harness packages (`@deepseek-ai/dsh-settings`, `@deepseek-ai/dsh`), and every
/// Harness package shares one version. Evaluating that range here is what turns
/// "the pinned plugin no longer matches this Runtime" into a verdict the app can act
/// on, instead of a plugin that installs and then fails inside Harness.
///
/// The supported grammar is the one plugins use: `||`-separated alternatives, each a
/// space-separated list of comparators (`^`, `~`, `>=`, `>`, `<=`, `<`, `=`, or a bare
/// version meaning an exact match). A range using anything else reports *undecidable*
/// rather than a verdict, so an unfamiliar spelling can never be mistaken for
/// incompatibility.
///
/// Prereleases are judged on the line they belong to. Every Harness release in this
/// project is a prerelease, and a plugin author writing `^0.1.1-rc.2` means "the 0.1
/// line from that build on", not "only the prerelease identifiers I happened to list".
/// The exception is a comparator naming the same `major.minor.patch` as the version
/// being judged: there the prerelease order decides, so an older prerelease of the
/// same line is still rejected. Reading the range strictly (as npm does for peer
/// dependencies) would reject every 0.1.x Harness build that a `^0.1.x` range plainly
/// covers.
public enum PluginCompatibility {
    /// Whether a version satisfies a declared range.
    ///
    /// - Parameters:
    ///   - version: Version to test, for example the installed Harness version.
    ///   - range: Declared range, for example `^0.1.1-rc.2 || ^0.2.0-rc.1`.
    /// - Returns: `true` when the range accepts the version, `false` when it rejects
    ///   it, and `nil` when the range cannot be read.
    public static func satisfies(_ version: String, range: String) -> Bool? {
        guard let subject = SemanticVersion(version) else { return nil }
        let alternatives = range
            .components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !alternatives.isEmpty else { return nil }

        // Every alternative is read before any is trusted: a range with one unreadable
        // part is undecidable as a whole, not satisfied by whichever part came first.
        var sets: [[Comparator]] = []
        for alternative in alternatives {
            guard !alternative.isEmpty else { return nil }
            let parts = alternative.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !parts.isEmpty else { return nil }
            var comparators: [Comparator] = []
            for part in parts {
                guard let comparator = Comparator(part) else { return nil }
                comparators.append(comparator)
            }
            sets.append(comparators)
        }
        return sets.contains { comparators in
            comparators.allSatisfy { $0.allows(subject) }
        }
    }
}

/// The comparison operators a plugin's declared range may use.
private enum ComparatorOperator {
    /// `=` or a bare version: the exact version.
    case equal
    /// `>`
    case greaterThan
    /// `>=`
    case greaterThanOrEqual
    /// `<`
    case lessThan
    /// `<=`
    case lessThanOrEqual
    /// `^`: compatible with the leftmost non-zero component.
    case caret
    /// `~`: compatible within the same minor version.
    case tilde
}

/// One parsed comparator: an operator and the version it applies to.
private struct Comparator {
    /// Operator the comparator was written with.
    let op: ComparatorOperator
    /// Version the operator applies to.
    let version: SemanticVersion

    /// Parses one comparator term, or returns `nil` for unsupported syntax.
    ///
    /// - Parameter text: One whitespace-separated comparator term.
    init?(_ text: String) {
        let operators: [(String, ComparatorOperator)] = [
            (">=", .greaterThanOrEqual),
            ("<=", .lessThanOrEqual),
            (">", .greaterThan),
            ("<", .lessThan),
            ("^", .caret),
            ("~", .tilde),
            ("=", .equal),
        ]
        var remainder = text
        var op = ComparatorOperator.equal
        for (prefix, candidate) in operators where text.hasPrefix(prefix) {
            op = candidate
            remainder = String(text.dropFirst(prefix.count))
            break
        }
        guard let version = SemanticVersion(remainder) else { return nil }
        // `~1` has no minor component to hold the upper bound, so it is not read
        // rather than read as something the author did not write.
        if op == .tilde, version.coreComponents < 2 { return nil }
        self.op = op
        self.version = version
    }

    /// Whether the comparator accepts a version.
    ///
    /// A released version is compared exactly as written. A prerelease is compared on
    /// the line it belongs to, unless this comparator names the same
    /// `major.minor.patch` — then the prerelease order decides, so an older prerelease
    /// of the same line is still rejected by a lower bound.
    ///
    /// - Parameter subject: Version to test.
    /// - Returns: `true` when the version is inside the comparator's bounds.
    func allows(_ subject: SemanticVersion) -> Bool {
        let exactPrerelease = subject.isPrerelease && version.isPrerelease && version.core == subject.core
        let onLine = subject.isPrerelease && !exactPrerelease
        let candidate = onLine ? subject.releaseOnly : subject
        let bound = onLine ? version.releaseOnly : version
        switch op {
        case .equal:
            return candidate == bound
        case .greaterThan:
            return candidate > bound
        case .greaterThanOrEqual:
            return candidate >= bound
        case .lessThan:
            return candidate < bound
        case .lessThanOrEqual:
            return candidate <= bound
        case .caret:
            return candidate >= bound && candidate < version.caretUpperBound
        case .tilde:
            return candidate >= bound && candidate < version.tildeUpperBound
        }
    }
}

/// A version as semantic versioning defines it: a numeric core and prerelease identifiers.
private struct SemanticVersion: Comparable, Equatable {
    /// `major`, `minor`, and `patch`; a missing component counts as zero.
    let core: [Int]
    /// Number of core components the version literally wrote.
    let coreComponents: Int
    /// Prerelease identifiers, empty for a released version.
    let prerelease: [String]

    /// Parses a version, ignoring build metadata.
    ///
    /// - Parameter text: Version text, for example `0.2.0-rc.1`.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let headAndPrerelease = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = headAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(coreParts.count) else { return nil }
        var core: [Int] = []
        for part in coreParts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part) else {
                return nil
            }
            core.append(value)
        }
        while core.count < 3 {
            core.append(0)
        }
        if headAndPrerelease.count == 2 {
            let identifiers = headAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            self.prerelease = identifiers
        } else {
            self.prerelease = []
        }
        self.core = core
        self.coreComponents = coreParts.count
    }

    /// Whether this version carries prerelease identifiers.
    var isPrerelease: Bool {
        !prerelease.isEmpty
    }

    /// The same version with its prerelease identifiers dropped.
    ///
    /// Used to judge a prerelease on the line it belongs to.
    var releaseOnly: SemanticVersion {
        SemanticVersion(core: core, coreComponents: 3, prerelease: [])
    }

    /// Highest version `^` accepts: the leftmost non-zero component is bumped.
    var caretUpperBound: SemanticVersion {
        var bound = core
        if bound[0] > 0 {
            bound = [bound[0] + 1, 0, 0]
        } else if bound[1] > 0 {
            bound = [0, bound[1] + 1, 0]
        } else {
            bound = [0, 0, bound[2] + 1]
        }
        return SemanticVersion(core: bound, coreComponents: 3, prerelease: [])
    }

    /// Highest version `~` accepts: the minor component is bumped.
    var tildeUpperBound: SemanticVersion {
        SemanticVersion(core: [core[0], core[1] + 1, 0], coreComponents: 3, prerelease: [])
    }

    /// Creates a version from parsed components.
    private init(core: [Int], coreComponents: Int, prerelease: [String]) {
        self.core = core
        self.coreComponents = coreComponents
        self.prerelease = prerelease
    }

    /// Orders two versions by the semantic-versioning rules.
    ///
    /// - Parameters:
    ///   - lhs: Left version.
    ///   - rhs: Right version.
    /// - Returns: `true` when the left version is lower.
    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<3 where lhs.core[index] != rhs.core[index] {
            return lhs.core[index] < rhs.core[index]
        }
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, false):
            return false
        case (false, true):
            // A released version outranks any prerelease of the same core.
            return false
        case (true, false):
            return true
        case (true, true):
            break
        }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            // Fewer identifiers lose only when every shared identifier matched.
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                // Numeric identifiers rank below alphanumeric ones.
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return false
    }
}
