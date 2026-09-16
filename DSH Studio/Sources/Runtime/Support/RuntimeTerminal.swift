//
//  RuntimeTerminal.swift
//  DSH Studio
//

import Foundation

/// Launch-time values used to create the private macOS DSH terminal.
public struct RuntimeTerminalConfiguration: Equatable, Sendable {
    public let stateDirectory: URL
    public let nodeExecutable: URL
    public let harnessEntry: URL
    public let pnpmExecutable: URL?
    public let dshHome: URL
    public let workspace: URL
    public let profileName: String

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

public struct RuntimeTerminalFiles: Equatable, Sendable {
    public let stateDirectory: URL
    public let shimDirectory: URL
    public let dshShim: URL
    public let nodeShim: URL
    public let pnpmShim: URL
    public let welcomeScript: URL

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

public enum RuntimeTerminalError: Error, Equatable, LocalizedError, Sendable {
    case invalidValue(String)
    case unsafeStateDirectory
    case writeFailed(String)

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

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

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
