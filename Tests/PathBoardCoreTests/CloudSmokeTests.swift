import XCTest
import Foundation
@testable import PathBoardCore

final class CloudSmokeTests: XCTestCase {
    func testMaterializedCloudMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["PATHBOARD_CLOUD_ROOTS_FILE"] else { throw XCTSkip("Real cloud smoke tests require explicitly configured disposable roots") }
        let roots = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let runID = "PathBoard-Test-" + UUID().uuidString
        var fixtures: [String: URL] = [:]
        var retained: [URL] = []
        defer {
            for url in retained { try? FileManager.default.removeItem(at: url) }
            for url in fixtures.values { try? FileManager.default.removeItem(at: url) }
        }
        for (name, root) in roots {
            let fixture = URL(fileURLWithPath: root).resolvingSymlinksInPath().appendingPathComponent(runID)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
            fixtures[name] = fixture
        }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(runID)
        defer { try? FileManager.default.removeItem(at: state) }
        let persistence = try Persistence(directory: state), engine = TransferEngine(persistence: persistence)
        var failures = 0
        for sourceName in fixtures.keys.sorted() {
            for targetName in fixtures.keys.sorted() {
                let fromRoot = fixtures[sourceName]!, toRoot = fixtures[targetName]!
                let folder = fromRoot.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
                try Data("PathBoard disposable cloud test [[unchanged]]".utf8).write(to: folder.appendingPathComponent("note.md"))
                try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
                let destination = toRoot.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let before = try FileSafety.snapshot(folder)
                let request = TransferRequest(sources: [folder], sourceRoot: fromRoot, destinationFolder: destination, destinationRoot: toRoot, operation: .move)
                let result = await engine.execute(request, token: CancellationToken(), collision: { _ in .rename })
                let record = try XCTUnwrap(result.first)
                if let path = record.retainedSource { retained.append(URL(fileURLWithPath: path)) }
                if record.phase != .completed {
                    failures += 1
                    print("CLOUD \(sourceName)->\(targetName): move requires review (source retained or Trash preserved)")
                    XCTAssertTrue(FileSafety.exists(folder) || record.retainedSource != nil, "No retained source")
                    continue
                }
                XCTAssertTrue(before.sameContent(as: try FileSafety.snapshot(URL(fileURLWithPath: record.destination))))
                let restored = try await engine.restore(record, allowedRoots: Array(fixtures.values), token: CancellationToken(), collision: { _ in .rename })
                if restored.phase != .restored { failures += 1 }
                XCTAssertEqual(restored.phase, .restored, "\(sourceName)->\(targetName): inverse transfer")
                XCTAssertTrue(before.sameContent(as: try FileSafety.snapshot(folder)))
                print("CLOUD \(sourceName)->\(targetName): materialized folder move and restore passed")
            }
        }
        for record in try persistence.records() {
            if let path = record.retainedSource { let url = URL(fileURLWithPath: path); if !retained.contains(url) { retained.append(url) } }
        }
        XCTAssertEqual(failures, 0, "Some cloud paths could not complete; do not mark them supported without investigation")
    }
}
