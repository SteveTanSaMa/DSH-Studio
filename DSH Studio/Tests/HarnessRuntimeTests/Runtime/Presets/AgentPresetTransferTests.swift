import Foundation
import XCTest
@testable import DeepSeekRuntime

final class AgentPresetTransferTests: XCTestCase {
    private var root: URL!
    private var dshHome: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-AgentPresetTransfer-\(UUID().uuidString)", isDirectory: true)
        dshHome = root.appendingPathComponent("DSH_HOME", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExportPreviewAndAtomicInstallRoundTrip() throws {
        let source = dshHome
            .appendingPathComponent(".agent-presets/custom", isDirectory: true)
        try write("- name: '@deepseek-ai/dsh-base'\n", to: source.appendingPathComponent("agent.cordis.yml"))
        try write("description: shared\n", to: source.appendingPathComponent("preset.yml"))
        try write("skill content\n", to: source.appendingPathComponent("skills/review/SKILL.md"))

        let manager = AgentPresetTransferManager(dshHome: dshHome)
        let archive = root.appendingPathComponent("custom.dshpreset")
        try manager.exportArchive(presetID: "custom", to: archive, sourceHarnessVersion: "0.1.1-rc.2")

        let preview = try manager.previewImport(from: archive, requestedID: "imported")
        XCTAssertEqual(preview.manifest.id, "custom")
        XCTAssertEqual(preview.targetID, "imported")
        XCTAssertFalse(preview.conflict)
        XCTAssertEqual(preview.fileCount, 3)
        XCTAssertTrue(preview.warnings.contains { $0.contains("可信来源") })

        let installed = try manager.installImport(from: archive, requestedID: "imported")
        XCTAssertEqual(installed.targetID, "imported")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dshHome.appendingPathComponent(".agent-presets/imported/agent.cordis.yml").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dshHome.appendingPathComponent(".agent-presets/imported/skills/review/SKILL.md").path
            )
        )
    }

    func testExportRejectsSymlinkedPresetContent() throws {
        let source = dshHome
            .appendingPathComponent(".agent-presets/custom", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        try write("outside\n", to: outside)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("- name: '@deepseek-ai/dsh-base'\n", to: source.appendingPathComponent("agent.cordis.yml"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try AgentPresetTransferManager(dshHome: dshHome)
                .exportArchive(presetID: "custom", to: root.appendingPathComponent("custom.dshpreset"))
        ) { error in
            guard case .symlinkNotAllowed("preset/linked.txt") = error as? AgentPresetTransferError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testImportRejectsMissingCompositionAndPreservesExistingPreset() throws {
        let archive = try makeArchive(
            manifest: """
            {"format":"dsh-preset","version":1,"id":"custom","name":"Custom","exportedAt":"2026-08-24T00:00:00Z"}
            """,
            files: ["preset/readme.txt": "no composition\n"]
        )
        let manager = AgentPresetTransferManager(dshHome: dshHome)

        XCTAssertThrowsError(try manager.previewImport(from: archive)) { error in
            XCTAssertEqual(error as? AgentPresetTransferError, .missingComposition)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dshHome.appendingPathComponent(".agent-presets/custom").path
            )
        )
    }

    func testImportWarnsAboutSensitiveMarkersAndRejectsConflict() throws {
        let existing = dshHome.appendingPathComponent(".agent-presets/custom", isDirectory: true)
        try write("- name: '@deepseek-ai/dsh-base'\n", to: existing.appendingPathComponent("agent.cordis.yml"))
        let archive = try makeArchive(
            manifest: """
            {"format":"dsh-preset","version":1,"id":"custom","name":"Custom","exportedAt":"2026-08-24T00:00:00Z"}
            """,
            files: [
                "preset/agent.cordis.yml": "- name: '@deepseek-ai/dsh-base'\n",
                "preset/settings.yml": "api_key: do-not-import\n"
            ]
        )
        let manager = AgentPresetTransferManager(dshHome: dshHome)
        let preview = try manager.previewImport(from: archive)

        XCTAssertTrue(preview.conflict)
        XCTAssertTrue(preview.warnings.contains { $0.contains("token") })
        XCTAssertThrowsError(try manager.installImport(from: archive)) { error in
            XCTAssertEqual(error as? AgentPresetTransferError, .conflict("custom"))
        }
        XCTAssertEqual(
            try String(
                contentsOf: existing.appendingPathComponent("agent.cordis.yml"),
                encoding: .utf8
            ),
            "- name: '@deepseek-ai/dsh-base'\n"
        )
    }

    func testImportRejectsNonUTF8Composition() throws {
        let archive = try makeArchive(
            manifest: "{\"format\":\"dsh-preset\",\"version\":1,\"id\":\"binary\",\"name\":\"Binary\",\"exportedAt\":\"2026-08-24T00:00:00Z\"}",
            dataFiles: ["preset/agent.cordis.yml": Data([0xC3, 0x28])]
        )
        let manager = AgentPresetTransferManager(dshHome: dshHome)

        XCTAssertThrowsError(try manager.previewImport(from: archive)) { error in
            XCTAssertEqual(error as? AgentPresetTransferError, .unsupportedFile("agent.cordis.yml"))
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func makeArchive(manifest: String, files: [String: String]) throws -> URL {
        let source = root.appendingPathComponent("archive-source-\(UUID().uuidString)", isDirectory: true)
        try write(manifest, to: source.appendingPathComponent("manifest.json"))
        for (path, contents) in files {
            try write(contents, to: source.appendingPathComponent(path))
        }
        let archive = root.appendingPathComponent("fixture-\(UUID().uuidString).dshpreset")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "manifest.json", "preset"]
        process.currentDirectoryURL = source
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func makeArchive(manifest: String, dataFiles: [String: Data]) throws -> URL {
        let source = root.appendingPathComponent("archive-source-\(UUID().uuidString)", isDirectory: true)
        try write(manifest, to: source.appendingPathComponent("manifest.json"))
        for (path, data) in dataFiles {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file)
        }
        let archive = root.appendingPathComponent("fixture-\(UUID().uuidString).dshpreset")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "manifest.json", "preset"]
        process.currentDirectoryURL = source
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }
}
