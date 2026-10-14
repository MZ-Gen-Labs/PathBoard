import XCTest
import Foundation
import Darwin
@testable import PathBoardCore

final class TransferTests: XCTestCase {
    var base: URL!; var a: URL!; var b: URL!; var trashFolder: URL!
    var persistence: Persistence!; var engine: TransferEngine!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("PathBoardTests-" + UUID().uuidString).resolvingSymlinksInPath()
        a = base.appendingPathComponent("A"); b = base.appendingPathComponent("B"); trashFolder = base.appendingPathComponent("Trash")
        for url in [a!, b!, trashFolder!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        persistence = try Persistence(directory: base.appendingPathComponent("State")); engine = TransferEngine(persistence: persistence)
        let trashRoot = trashFolder!
        engine.trash = { source in
            let target = trashRoot.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileSafety.renameExclusively(source, to: target); return target
        }
    }
    override func tearDownWithError() throws { if let base { try FileManager.default.removeItem(at: base) } }
    @discardableResult func file(_ name: String, in folder: URL? = nil, text: String = "原文 [[ノート]]") throws -> URL {
        let url = (folder ?? a!).appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    func request(_ sources: [URL], operation: TransferOperation = .copy, destination: URL? = nil) -> TransferRequest {
        TransferRequest(sources: sources, sourceRoot: a, destinationFolder: destination ?? b, destinationRoot: destination == nil ? b : a, operation: operation)
    }
    func run(_ request: TransferRequest, token: CancellationToken = CancellationToken(), choice: CollisionChoice = .rename) async -> [TransferRecord] {
        await engine.execute(request, token: token, collision: { _ in choice })
    }
    func testCopyContentsAndPersistentHistory() async throws {
        let source = try file("ノート.md"); let before = try FileSafety.snapshot(source)
        let results = await run(request([source]))
        XCTAssertEqual(results.first?.phase, .completed)
        XCTAssertEqual(try FileSafety.snapshot(source), before)
        XCTAssertTrue(before.sameContent(as: try FileSafety.snapshot(b.appendingPathComponent("ノート.md"))))
        let reopened = try Persistence(directory: persistence.directory)
        XCTAssertEqual(try reopened.records().first?.phase, .completed)
    }
    func testMoveAndRestoreAfterRestart() async throws {
        let source = try file("note.md"); let before = try FileSafety.snapshot(source)
        let results = await run(request([source], operation: .move)); let moved = try XCTUnwrap(results.first)
        XCTAssertEqual(moved.phase, .completed); XCTAssertFalse(FileSafety.exists(source))
        XCTAssertTrue(FileSafety.exists(URL(fileURLWithPath: try XCTUnwrap(moved.retainedSource))))
        let restored = try await engine.restore(moved, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename })
        XCTAssertEqual(restored.phase, .restored); XCTAssertTrue(before.sameContent(as: try FileSafety.snapshot(source)))
        XCTAssertFalse(FileSafety.exists(b.appendingPathComponent("note.md")))
        do { _ = try await engine.restore(moved, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename }); XCTFail("Must not restore twice") } catch {}
    }
    func testHiddenAndEmptyFolders() async throws {
        let folder = a.appendingPathComponent("Vault"); try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try file(".hidden", in: folder); try file("note.md", in: folder)
        let before = try FileSafety.snapshot(folder); let results = await run(request([folder]))
        XCTAssertEqual(results.first?.phase, .completed); XCTAssertTrue(before.sameContent(as: try FileSafety.snapshot(b.appendingPathComponent("Vault"))))
    }
    func testCollisionNeverOverwrites() async throws {
        let source = try file("note.md"); let existing = try file("note.md", in: b, text: "既存")
        let before = try FileSafety.snapshot(existing); let results = await run(request([source]))
        XCTAssertEqual(results.first?.phase, .completed); XCTAssertEqual(results.first?.destination, b.appendingPathComponent("note (1).md").path)
        XCTAssertEqual(try FileSafety.snapshot(existing), before)
    }
    func testCollisionSkipAndCancel() async throws {
        let source = try file("same"); try file("same", in: b)
        let skipped = await run(request([source]), choice: .skip); XCTAssertEqual(skipped.first?.phase, .skipped)
        let cancelled = await run(request([source], operation: .move), choice: .cancel); XCTAssertEqual(cancelled.first?.phase, .cancelled)
        XCTAssertTrue(FileSafety.exists(source))
    }
    func testLateCollisionKeepsSourceAndExistingTarget() async throws {
        let source = try file("same"); let target = b.appendingPathComponent("same")
        engine.checkpoint = { point, _ in if point == .beforeCommit { try Data("競合".utf8).write(to: target) } }
        let results = await run(request([source], operation: .move)); XCTAssertNotEqual(results.first?.phase, .completed)
        XCTAssertTrue(FileSafety.exists(source)); XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "競合")
    }
    func testContentChangeWithSameSizeStopsDeletion() async throws {
        let source = try file("same", text: "ABCD")
        engine.checkpoint = { point, _ in if point == .afterCopy { try Data("WXYZ".utf8).write(to: source) } }
        let results = await run(request([source], operation: .move)); XCTAssertNotEqual(results.first?.phase, .completed)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "WXYZ")
    }
    func testCorruptedCopyStopsDeletion() async throws {
        let source = try file("same"); let destinationRoot = b!
        engine.checkpoint = { point, record in if point == .afterCopy { try Data("破損".utf8).write(to: destinationRoot.appendingPathComponent(".pathboard-\(record.id.uuidString).partial")) } }
        let results = await run(request([source], operation: .move)); XCTAssertNotEqual(results.first?.phase, .completed); XCTAssertTrue(FileSafety.exists(source))
    }
    func testSourceChangedBeforeRemovalRetainsBoth() async throws {
        let source = try file("same")
        engine.checkpoint = { point, _ in if point == .beforeRemoval { try Data("編集後".utf8).write(to: source) } }
        let results = await run(request([source], operation: .move)); XCTAssertEqual(results.first?.phase, .needsReview)
        XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testDestinationChangedBeforeRemovalRetainsSource() async throws {
        let source = try file("same"); let target = b.appendingPathComponent("same")
        engine.checkpoint = { point, _ in if point == .beforeRemoval { try Data("競合後".utf8).write(to: target) } }
        let results = await run(request([source], operation: .move)); XCTAssertEqual(results.first?.phase, .needsReview); XCTAssertTrue(FileSafety.exists(source))
    }
    func testTrashFailureRetainsCompleteCopyAndSource() async throws {
        let source = try file("same"); engine.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        let results = await run(request([source], operation: .move)); XCTAssertEqual(results.first?.phase, .needsReview)
        XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testCancelDuringVerificationKeepsSource() async throws {
        let source = try file("same"); let token = CancellationToken()
        engine.checkpoint = { point, _ in if point == .afterCopy { token.cancel() } }
        let results = await run(request([source], operation: .move), token: token); XCTAssertEqual(results.first?.phase, .cancelled); XCTAssertTrue(FileSafety.exists(source))
    }
    func testInterruptionAfterCommitNeverAutomaticallyDeletesSource() async throws {
        let source = try file("same")
        engine.checkpoint = { point, _ in if point == .afterCommit { throw PathBoardError.unsafe("強制中断") } }
        let results = await run(request([source], operation: .move)); XCTAssertEqual(results.first?.phase, .needsReview)
        _ = try Persistence(directory: persistence.directory).records()
        XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testHistoryWriteFailurePreventsDeletion() async throws {
        let source = try file("same"); let history = persistence.directory.appendingPathComponent("History")
        try FileManager.default.removeItem(at: history); try Data().write(to: history)
        let results = await run(request([source], operation: .move)); XCTAssertNotEqual(results.first?.phase, .completed); XCTAssertTrue(FileSafety.exists(source))
    }
    func testUnsafeDestinationsAndUnregisteredSource() async throws {
        let source = try file("same"); let outside = try file("outside", in: base)
        let selfResult = await run(request([source], operation: .move, destination: a)); XCTAssertNotEqual(selfResult.first?.phase, .completed)
        let outsideResult = await run(request([outside])); XCTAssertNotEqual(outsideResult.first?.phase, .completed); XCTAssertTrue(FileSafety.exists(outside))
        let folder = a.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: folder.appendingPathComponent("child"), withIntermediateDirectories: true)
        let nested = await run(request([folder], operation: .move, destination: folder.appendingPathComponent("child"))); XCTAssertNotEqual(nested.first?.phase, .completed)
    }
    func testParentChildSelectionDeduplicates() throws {
        let parent = a.appendingPathComponent("folder")
        XCTAssertEqual(FileSafety.normalizedSources([parent, parent.appendingPathComponent("child"), parent]), [parent])
    }
    func testSymlinkNeverTraversed() async throws {
        let source = try file("same"); let link = a.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let results = await run(request([link], operation: .move)); XCTAssertNotEqual(results.first?.phase, .completed); XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(link))
        let destLink = b.appendingPathComponent("outside"); try FileManager.default.createSymbolicLink(at: destLink, withDestinationURL: base)
        XCTAssertThrowsError(try FileSafety.validate(destLink.appendingPathComponent("x"), inside: b))
    }
    func testHardlinksAndPackagesRejected() throws {
        let source = try file("same"); try FileManager.default.linkItem(at: source, to: a.appendingPathComponent("hardlink"))
        XCTAssertThrowsError(try FileSafety.snapshot(source))
        let app = a.appendingPathComponent("Test.app"); try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileSafety.snapshot(app))
    }
    func testChangedRestoreDoesNotDelete() async throws {
        let source = try file("same"); let results = await run(request([source], operation: .move)); let moved = try XCTUnwrap(results.first)
        let target = b.appendingPathComponent("same"); try Data("編集".utf8).write(to: target)
        do { _ = try await engine.restore(moved, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename }); XCTFail("Changed file must not restore") } catch {}
        XCTAssertTrue(FileSafety.exists(target)); XCTAssertFalse(FileSafety.exists(source))
    }
    func testRestoreWithCollisionAndOriginalFilename() async throws {
        let source = try file("note.md"); try file("note.md", in: b, text: "既存先")
        let results = await run(request([source], operation: .move)); let moved = try XCTUnwrap(results.first)
        try file("note.md", text: "新しい元")
        let restored = try await engine.restore(moved, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename })
        XCTAssertEqual(restored.phase, .restored); XCTAssertTrue(FileSafety.exists(a.appendingPathComponent("note (1).md")))
        XCTAssertEqual(try String(contentsOf: a.appendingPathComponent("note.md"), encoding: .utf8), "新しい元")
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("note.md"), encoding: .utf8), "既存先")
    }
    func testCopyUndoAndTrashFailureNeverPermanentlyDelete() async throws {
        let source = try file("same"); let results = await run(request([source])); let copied = try XCTUnwrap(results.first)
        engine.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        do { _ = try await engine.restore(copied, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename }); XCTFail("Trash failure") } catch {}
        XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testCopyUndoSuccessful() async throws {
        let source = try file("same"); let results = await run(request([source])); let copied = try XCTUnwrap(results.first)
        let restored = try await engine.restore(copied, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename })
        XCTAssertEqual(restored.phase, .restored); XCTAssertTrue(FileSafety.exists(source)); XCTAssertFalse(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testRestoreRequiresRegisteredRoots() async throws {
        let source = try file("same"); let results = await run(request([source])); let copied = try XCTUnwrap(results.first)
        do { _ = try await engine.restore(copied, allowedRoots: [a], token: CancellationToken(), collision: { _ in .rename }); XCTFail("Unregistered root") } catch {}
        XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testSnapshotDetectsAttributeChanges() throws {
        let source = try file("same"); let before = try FileSafety.snapshot(source)
        let bytes = Array("タグ".utf8)
        let rc = bytes.withUnsafeBytes { setxattr(source.path, "user.pathboard-test", $0.baseAddress, $0.count, 0, 0) }; XCTAssertEqual(rc, 0)
        XCTAssertNotEqual(try FileSafety.snapshot(source), before)
    }
    func testPreferencesRoundtripAndCorruptionPreserved() throws {
        var preferences = Preferences(); preferences.workspaces[0].panels[0].rootPath = a.path
        preferences.workspaces[0].panels[0].expandedPaths = [a.appendingPathComponent("folder").path]; preferences.workspaces[0].verticalRatio = 0.6
        try persistence.savePreferences(preferences); let restored = try persistence.loadPreferences()
        XCTAssertEqual(restored.workspaces, preferences.workspaces)
        let url = persistence.directory.appendingPathComponent("Preferences.json"); try Data("bad".utf8).write(to: url)
        XCTAssertThrowsError(try persistence.loadPreferences()); XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bad")
    }
    func testClearHistoryDoesNotTouchData() async throws {
        let source = try file("same"); _ = await run(request([source])); try persistence.clearHistory()
        XCTAssertTrue(try persistence.records().isEmpty); XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }
    func testDirectoryCollisionKeepsDotInFolderName() async throws {
        let folder = a.appendingPathComponent("folder.backup"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try file("folder.backup", in: b)
        let results = await run(request([folder])); XCTAssertEqual(results.first?.phase, .completed)
        XCTAssertEqual(results.first?.destination, b.appendingPathComponent("folder.backup (1)").path)
    }
    func testConcurrentRequestsAreSerialized() async throws {
        let source = try file("same")
        async let first = engine.execute(request([source]), token: CancellationToken(), collision: { _ in .rename })
        async let second = engine.execute(request([source]), token: CancellationToken(), collision: { _ in .rename })
        let results = await (first, second)
        XCTAssertEqual(results.0.first?.phase, .completed); XCTAssertEqual(results.1.first?.phase, .completed)
        XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same"))); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same (1)")))
    }
    func testRestoreSkipCanBeRetried() async throws {
        let source = try file("same"); let forward = await run(request([source], operation: .move)); let original = try XCTUnwrap(forward.first)
        try file("same", text: "後で作った項目")
        let skipped = try await engine.restore(original, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .skip })
        XCTAssertTrue(skipped.canRestore)
        let restored = try await engine.restore(skipped, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename })
        XCTAssertEqual(restored.phase, .restored)
    }
    func testEmptyFileAndPermissionMetadata() async throws {
        let source = try file("empty", text: ""); try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let results = await run(request([source])); XCTAssertEqual(results.first?.phase, .completed)
        XCTAssertTrue(try FileSafety.snapshot(source).sameContent(as: FileSafety.snapshot(b.appendingPathComponent("empty"))))
    }
    func testLargeFileStreamingAndCancellation() throws {
        let source = a.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        for _ in 0..<32 { try handle.write(contentsOf: Data(repeating: 0x57, count: 1024*1024)) }; try handle.close()
        let first = try FileSafety.snapshot(source); XCTAssertEqual(first.entries[0].size, 32*1024*1024)
        let token = CancellationToken(); token.cancel(); XCTAssertThrowsError(try FileSafety.snapshot(source, token: token))
    }
    func testCorruptHistoryStopsRestore() async throws {
        let source = try file("same"); let results = await run(request([source])); let record = try XCTUnwrap(results.first)
        let history = persistence.directory.appendingPathComponent("History/\(record.id.uuidString).json"); try Data("broken".utf8).write(to: history)
        do { _ = try await engine.restore(record, allowedRoots: [a,b], token: CancellationToken(), collision: { _ in .rename }); XCTFail("Broken journal must stop") } catch {}
        XCTAssertTrue(FileSafety.exists(source)); XCTAssertTrue(FileSafety.exists(b.appendingPathComponent("same")))
    }

    func testSystemTrashPreservesGeneratedOriginal() async throws {
        let source = try file("PathBoardDisposable-" + UUID().uuidString + ".txt")
        let actualEngine = TransferEngine(persistence: persistence)
        let results = await actualEngine.execute(request([source], operation: .move), token: CancellationToken(), collision: { _ in .rename })
        let record = try XCTUnwrap(results.first)
        XCTAssertEqual(record.phase, .completed, record.message)
        let retained = URL(fileURLWithPath: try XCTUnwrap(record.retainedSource))
        defer { try? FileManager.default.removeItem(at: retained) }
        XCTAssertTrue(FileSafety.exists(retained)); XCTAssertFalse(FileSafety.exists(source))
        XCTAssertTrue(try FileSafety.snapshot(retained).sameContent(as: FileSafety.snapshot(URL(fileURLWithPath: record.destination))))
    }

}
