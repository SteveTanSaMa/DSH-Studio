//
//  RuntimeTerminal.swift
//  DSH Studio
//

import Foundation

/// Launch-time values used to create the private macOS DSH terminal.
public struct RuntimeTerminalConfiguration: Equatable, Sendable {
    /// Directory that receives the generated shims and shell files.
    public let stateDirectory: URL
    /// Node.js binary the generated shims invoke.
    public let nodeExecutable: URL
    /// Harness entry point the `dsh` shim runs.
    public let harnessEntry: URL
    /// pnpm binary used for profile commands, when the Runtime provides one.
    public let pnpmExecutable: URL?
    /// Harness data home exported inside the terminal.
    public let dshHome: URL
    /// Workspace directory the terminal starts in.
    public let workspace: URL
    /// Harness profile the terminal is scoped to.
    public let profileName: String

    /// Creates a terminal configuration, standardizing every file URL.
    ///
    /// - Parameters:
    ///   - stateDirectory: Directory that will hold the generated files.
    ///   - nodeExecutable: Node.js binary the shims invoke.
    ///   - harnessEntry: Harness entry point the `dsh` shim runs.
    ///   - pnpmExecutable: pnpm binary, when the Runtime provides one.
    ///   - dshHome: Harness data home to export.
    ///   - workspace: Directory the terminal starts in.
    ///   - profileName: Harness profile to scope the terminal to.
    public init(
        stateDirectory: URL,
        nodeExecutable: URL,
        harnessEntry: URL,
        pnpmExecutable: URL?,
        dshHome: URL,
        workspace: URL,
        profileName: String
    ) {
        self.stateDirectory = stateDirectory.standardizedFileURL
        self.nodeExecutable = nodeExecutable.standardizedFileURL
        self.harnessEntry = harnessEntry.standardizedFileURL
        self.pnpmExecutable = pnpmExecutable?.standardizedFileURL
        self.dshHome = dshHome.standardizedFileURL
        self.workspace = workspace.standardizedFileURL
        self.profileName = profileName
    }
}

/// Paths written for one generated terminal.
public struct RuntimeTerminalFiles: Equatable, Sendable {
    /// Directory holding the generated files.
    public let stateDirectory: URL
    /// Directory holding the `dsh`, `node`, and `pnpm` shims.
    public let shimDirectory: URL
    /// Shim that runs Harness with the exported environment.
    public let dshShim: URL
    /// Shim that pins the Runtime's Node.js binary.
    public let nodeShim: URL
    /// Shim that pins the Runtime's pnpm and profile directory.
    public let pnpmShim: URL
    /// Double-clickable script that opens the configured shell.
    public let welcomeScript: URL

    /// Creates the file list for one prepared terminal.
    ///
    /// - Parameters:
    ///   - stateDirectory: Directory holding the generated files.
    ///   - shimDirectory: Directory holding the command shims.
    ///   - dshShim: Path of the `dsh` shim.
    ///   - nodeShim: Path of the `node` shim.
    ///   - pnpmShim: Path of the `pnpm` shim.
    ///   - welcomeScript: Path of the launcher script.
    public init(
        stateDirectory: URL,
        shimDirectory: URL,
        dshShim: URL,
        nodeShim: URL,
        pnpmShim: URL,
        welcomeScript: URL
    ) {
        self.stateDirectory = stateDirectory
        self.shimDirectory = shimDirectory
        self.dshShim = dshShim
        self.nodeShim = nodeShim
        self.pnpmShim = pnpmShim
        self.welcomeScript = welcomeScript
    }
}

/// Failures raised while generating a terminal environment.
public enum RuntimeTerminalError: Error, Equatable, LocalizedError, Sendable {
    /// A configuration value is missing or unsafe; carries the rejected value.
    case invalidValue(String)
    /// The state directory is not a private directory owned by DSH Studio.
    case unsafeStateDirectory
    /// A generated file could not be written; carries the underlying detail.
    case writeFailed(String)

    /// A localized, user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidValue(let value):
            return "终端配置无效：\(value)"
        case .unsafeStateDirectory:
            return "终端目录不是受 DSH Studio 管理的私有目录"
        case .writeFailed(let detail):
            return "终端文件生成失败：\(detail)"
        }
    }
}

/// Creates a private, profile-aware command environment for one terminal.
///
/// The generated files are deliberately ordinary shell shims. They only add
/// environment variables inside the terminal process tree and never edit the
/// user's shell rc files or persistent PATH.
public final class RuntimeTerminalFileGenerator: @unchecked Sendable {
    private let fileManager: FileManager

    /// Creates a generator.
    ///
    /// - Parameter fileManager: File system seam used by tests.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Writes the shims, private shell file, and welcome script for a terminal.
    ///
    /// Existing generated files are replaced in place; the user's shell rc files and
    /// persistent `PATH` are never touched.
    ///
    /// - Parameter configuration: Launch-time values for the terminal.
    /// - Returns: The paths that were written.
    /// - Throws: ``RuntimeTerminalError`` when a value is unsafe, the state directory
    ///   is not app-owned, or a file cannot be written.
    public func prepare(configuration: RuntimeTerminalConfiguration) throws -> RuntimeTerminalFiles {
        try validate(configuration)
        let stateDirectory = configuration.stateDirectory
        let shimDirectory = stateDirectory.appendingPathComponent("bin", isDirectory: true)
        try preparePrivateDirectory(stateDirectory)
        try preparePrivateDirectory(shimDirectory)

        let files = RuntimeTerminalFiles(
            stateDirectory: stateDirectory,
            shimDirectory: shimDirectory,
            dshShim: shimDirectory.appendingPathComponent("dsh"),
            nodeShim: shimDirectory.appendingPathComponent("node"),
            pnpmShim: shimDirectory.appendingPathComponent("pnpm"),
            welcomeScript: stateDirectory.appendingPathComponent("welcome.command")
        )

        let nodeDirectory = configuration.nodeExecutable.deletingLastPathComponent().path
        let profileDirectory = configuration.dshHome
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(configuration.profileName, isDirectory: true)

        try replacePrivateFile(
            files.dshShim,
            contents: dshShim(
                configuration: configuration,
                shimDirectory: shimDirectory,
                nodeDirectory: nodeDirectory
            ),
            mode: 0o700
        )
        try replacePrivateFile(
            files.nodeShim,
            contents: nodeShim(configuration: configuration),
            mode: 0o700
        )
        try replacePrivateFile(
            files.pnpmShim,
            contents: pnpmShim(configuration: configuration, shimDirectory: shimDirectory, profileDirectory: profileDirectory),
            mode: 0o700
        )
        try replacePrivateFile(
            stateDirectory.appendingPathComponent(".zshrc"),
            contents: zshrc(configuration: configuration, shimDirectory: shimDirectory),
            mode: 0o600
        )
        try replacePrivateFile(
            files.welcomeScript,
            contents: welcomeScript(configuration: configuration, shimDirectory: shimDirectory),
            mode: 0o700
        )
        return files
    }

    private func validate(_ configuration: RuntimeTerminalConfiguration) throws {
        let values: [(String, String)] = [
            ("stateDirectory", configuration.stateDirectory.path),
            ("nodeExecutable", configuration.nodeExecutable.path),
            ("harnessEntry", configuration.harnessEntry.path),
            ("dshHome", configuration.dshHome.path),
            ("workspace", configuration.workspace.path),
            ("profileName", configuration.profileName)
        ] + (configuration.pnpmExecutable.map { [("pnpmExecutable", $0.path)] } ?? [])
        for (label, value) in values {
            guard !value.isEmpty, !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
                throw RuntimeTerminalError.invalidValue(label)
            }
        }
        guard HarnessProfileStore.isSafeName(configuration.profileName) else {
            throw RuntimeTerminalError.invalidValue("profileName")
        }
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw RuntimeTerminalError.unsafeStateDirectory
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch let error as RuntimeTerminalError {
            throw error
        } catch {
            throw RuntimeTerminalError.writeFailed(error.localizedDescription)
        }
    }

    private func replacePrivateFile(_ url: URL, contents: String, mode: Int) throws {
        do {
            if fileManager.fileExists(atPath: url.path),
               (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw RuntimeTerminalError.unsafeStateDirectory
            }
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            try Data(contents.utf8).write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporary, to: url)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch let error as RuntimeTerminalError {
            throw error
        } catch {
            throw RuntimeTerminalError.writeFailed(error.localizedDescription)
        }
    }

    private func dshShim(
        configuration: RuntimeTerminalConfiguration,
        shimDirectory: URL,
        nodeDirectory: String
    ) -> String {
        let node = shellQuote(configuration.nodeExecutable.path)
        let entry = shellQuote(configuration.harnessEntry.path)
        let home = shellQuote(configuration.dshHome.path)
        let profile = shellQuote(configuration.profileName)
        let shim = shellQuote(shimDirectory.path)
        let nodeDir = shellQuote(nodeDirectory)
        return """
        #!/bin/zsh
        set -e
        unset ELECTRON_RUN_AS_NODE
        export DSH_HOME=\(home)
        export PATH=\(shim):\(nodeDir):${PATH:-}
        default_profile=\(profile)
        has_profile=0
        for argument in "$@"; do
          if [[ "$argument" == "--profile" || "$argument" == --profile=* ]]; then
            has_profile=1
            break
          fi
        done
        if [[ "${1:-}" == "plugin" ]]; then
          if (( has_profile )); then
            exec \(node) \(entry) "$@"
          fi
          shift
          exec \(node) \(entry) plugin --profile "$default_profile" "$@"
        fi
        if [[ "${1:-}" == "web" || "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
          exec \(node) \(entry) "$@"
        fi
        if (( has_profile )); then
          exec \(node) \(entry) "$@"
        fi
        exec \(node) \(entry) --profile "$default_profile" "$@"
        """ + "\n"
    }

    private func nodeShim(configuration: RuntimeTerminalConfiguration) -> String {
        """
        #!/bin/zsh
        unset ELECTRON_RUN_AS_NODE
        exec \(shellQuote(configuration.nodeExecutable.path)) "$@"
        """ + "\n"
    }

    private func pnpmShim(
        configuration: RuntimeTerminalConfiguration,
        shimDirectory: URL,
        profileDirectory: URL
    ) -> String {
        let home = shellQuote(configuration.dshHome.path)
        let shim = shellQuote(shimDirectory.path)
        let profile = shellQuote(profileDirectory.path)
        guard let pnpm = configuration.pnpmExecutable else {
            return """
            #!/bin/zsh
            print -u2 "DSH Studio pnpm is unavailable for the active Runtime."
            exit 127
            """ + "\n"
        }
        return """
        #!/bin/zsh
        set -e
        unset ELECTRON_RUN_AS_NODE
        export DSH_HOME=\(home)
        export PATH=\(shim):${PATH:-}
        if [[ -d \(profile) ]]; then cd \(profile); else cd \(home); fi
        exec \(shellQuote(pnpm.path)) "$@"
        """ + "\n"
    }

    private func zshrc(
        configuration: RuntimeTerminalConfiguration,
        shimDirectory: URL
    ) -> String {
        let home = shellQuote(configuration.dshHome.path)
        let shim = shellQuote(shimDirectory.path)
        return """
        if [[ -n "${DSH_STUDIO_USER_ZDOTDIR:-}" && -r "${DSH_STUDIO_USER_ZDOTDIR}/.zshrc" ]]; then
          source "${DSH_STUDIO_USER_ZDOTDIR}/.zshrc"
        fi
        unset ELECTRON_RUN_AS_NODE
        export DSH_HOME=\(home)
        typeset -U path
        path=(\(shim) $path)
        export PATH
        unset DSH_STUDIO_USER_ZDOTDIR
        printf '%s\\n' 'DSH Studio terminal'
        printf '%s\\n' 'Profile: '"$DSH_STUDIO_PROFILE"
        printf '%s\\n' 'Workspace: '"$DSH_STUDIO_WORKSPACE"
        printf '%s\\n' 'Harness home: '"$DSH_HOME"
        printf '%s\\n' 'Use `dsh --help` for commands; plugin commands without --profile use the selected Profile.'
        """ + "\n"
    }

    private func welcomeScript(
        configuration: RuntimeTerminalConfiguration,
        shimDirectory: URL
    ) -> String {
        let home = shellQuote(configuration.dshHome.path)
        let workspace = shellQuote(configuration.workspace.path)
        let shim = shellQuote(shimDirectory.path)
        let state = shellQuote(configuration.stateDirectory.path)
        let profile = shellQuote(configuration.profileName)
        return """
        #!/bin/sh
        set -e
        unset ELECTRON_RUN_AS_NODE
        export DSH_HOME=\(home)
        export DSH_STUDIO_PROFILE=\(profile)
        export DSH_STUDIO_WORKSPACE=\(shellQuote(configuration.workspace.path))
        export PATH=\(shim):${PATH:-}
        export DSH_STUDIO_USER_ZDOTDIR="${ZDOTDIR:-${HOME:-}}"
        export ZDOTDIR=\(state)
        cd \(workspace)
        exec /bin/zsh -i
        """ + "\n"
    }

    private func shellQuote(_ value: String) -> String {
        let replacement = "'\"'\"'"
        return "'\(value.replacingOccurrences(of: "'", with: replacement))'"
    }
}
