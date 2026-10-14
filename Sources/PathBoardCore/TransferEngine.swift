import Foundation

private actor JobGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

public enum TransferCheckpoint { case afterCopy, beforeCommit, afterCommit, beforeRemoval, afterRemoval }
public final class TransferEngine: @unchecked Sendable {
    public typealias CollisionHandler = (URL) async -> CollisionChoice
    public typealias Progress = (TransferRecord) -> Void
    public let persistence: Persistence
    private let gate = JobGate()
    public var checkpoint: ((TransferCheckpoint, TransferRecord) throws -> Void)?
    public var trash: (URL) throws -> URL = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw PathBoardError.unsafe("ゴミ箱への保全先を確認できませんでした。") }
        return result as URL
    }
    public init(persistence: Persistence) { self.persistence = persistence }
    private func publish(_ record: TransferRecord, progress: Progress) throws { try persistence.save(record); progress(record) }
    private func coordinated<T>(source: URL, destination: URL, body: (URL, URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var outcome: Result<T, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: [], error: &error) { a, b in
            outcome = Result { try body(a, b) }
        }
        if let error { throw error }
        guard let outcome else { throw PathBoardError.unsafe("保存先へのアクセス調整に失敗しました。") }
        return try outcome.get()
    }
    public func execute(_ request: TransferRequest, token: CancellationToken, collision: @escaping CollisionHandler, progress: @escaping Progress = { _ in }) async -> [TransferRecord] {
        await gate.acquire()
        let results = await executeUnlocked(request, token: token, collision: collision, progress: progress)
        await gate.release()
        return results
    }
    private func executeUnlocked(_ request: TransferRequest, token: CancellationToken, collision: @escaping CollisionHandler, progress: @escaping Progress, parentID: UUID? = nil, destinationName: String? = nil, expectedSnapshot: Snapshot? = nil) async -> [TransferRecord] {
        var results: [TransferRecord] = []
        for source in FileSafety.normalizedSources(request.sources) {
            if token.isCancelled { break }
            var record = TransferRecord(operation: request.operation, source: source, destination: request.destinationFolder.appendingPathComponent(destinationName ?? source.lastPathComponent), sourceRoot: request.sourceRoot, destinationRoot: request.destinationRoot)
            record.parentRecordID = parentID
            do {
                try FileSafety.validate(source, inside: request.sourceRoot)
                try FileSafety.validate(request.destinationFolder, inside: request.destinationRoot, allowRoot: true)
                guard request.destinationFolder.path != source.path && !request.destinationFolder.path.hasPrefix(source.path + "/"), record.source != record.destination else { throw PathBoardError.unsafe("自分自身や配下への転送はできません。") }
                try publish(record, progress: progress)
                var destination = URL(fileURLWithPath: record.destination)
                if FileSafety.exists(destination) {
                    switch await collision(destination) {
                    case .cancel: token.cancel(); throw PathBoardError.cancelled
                    case .skip: record.phase = .skipped; try publish(record, progress: progress); results.append(record); continue
                    case .rename: destination = FileSafety.availableName(destination, isDirectory: (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true); record.destination = destination.path
                    }
                }
                try token.check()
                try coordinated(source: source, destination: request.destinationFolder) { coordinatedSource, coordinatedFolder in
                    guard coordinatedSource.standardizedFileURL.path == source.standardizedFileURL.path, coordinatedFolder.standardizedFileURL.path == request.destinationFolder.standardizedFileURL.path else { throw PathBoardError.changed }
                    try FileSafety.validate(source, inside: request.sourceRoot)
                    try FileSafety.validate(destination, inside: request.destinationRoot)
                    let before = try FileSafety.snapshot(source, token: token)
                    if let expected = expectedSnapshot, expected != before { throw PathBoardError.changed }
                    let temporary = request.destinationFolder.appendingPathComponent(".pathboard-\(record.id.uuidString).partial")
                    guard !FileSafety.exists(temporary) else { throw PathBoardError.unsafe("一時保存先がすでに存在します。") }
                    var created = false
                    defer { if created && FileSafety.exists(temporary) { try? FileManager.default.removeItem(at: temporary) } }
                    record.temporaryPath = temporary.path
                    record.phase = .copying; try publish(record, progress: progress)
                    try token.check()
                    // copyItem never overwrites. Partial failures are retained, not blindly deleted.
                    try FileManager.default.copyItem(at: source, to: temporary); created = true
                    try checkpoint?(.afterCopy, record)
                    record.phase = .verifying; try publish(record, progress: progress)
                    let copied = try FileSafety.snapshot(temporary, token: token)
                    guard before.sameContent(as: copied), before == (try FileSafety.snapshot(source, token: token)) else { throw PathBoardError.changed }
                    try token.check(); try checkpoint?(.beforeCommit, record)
                    try FileSafety.validate(destination, inside: request.destinationRoot)
                    try FileSafety.renameExclusively(temporary, to: destination); created = false; record.temporaryPath = nil
                    record.snapshot = try FileSafety.snapshot(destination, token: token)
                    guard before.sameContent(as: record.snapshot!) else { throw PathBoardError.changed }
                    record.phase = .committed; try publish(record, progress: progress)
                    try checkpoint?(.afterCommit, record)
                    if request.operation == .move {
                        try token.check()
                        try checkpoint?(.beforeRemoval, record)
                        try FileSafety.validate(source, inside: request.sourceRoot)
                        try FileSafety.validate(destination, inside: request.destinationRoot)
                        guard before == (try FileSafety.snapshot(source, token: token)), record.snapshot == (try FileSafety.snapshot(destination, token: token)) else { throw PathBoardError.changed }
                        record.phase = .removingSource; try publish(record, progress: progress)
                        // Keep a recoverable original in Trash; never fall back to permanent deletion.
                        let retained = try trash(source)
                        record.retainedSource = retained.path
                        try publish(record, progress: progress)
                        guard before == (try FileSafety.snapshot(retained)) else { throw PathBoardError.changed }
                        try checkpoint?(.afterRemoval, record)
                    }
                    record.phase = .completed; record.message = request.operation == .move ? "コピーを検証し、元データをゴミ箱へ保全しました。クラウド同期完了は未確認です。" : "コピーを検証しました。クラウド同期完了は未確認です。"
                    try publish(record, progress: progress)
                }
            } catch {
                let hasCommitted = record.snapshot != nil
                record.phase = token.isCancelled ? .cancelled : (hasCommitted ? .needsReview : .failed)
                record.message = error.localizedDescription + (hasCommitted ? " コピー先を残しています。元データ・ゴミ箱を確認してください。" : " 元データは削除していません。")
                do { try publish(record, progress: progress) } catch { record.message += " 履歴の保存にも失敗しました。"; progress(record) }
                if case PathBoardError.cancelled = error { token.cancel() }
            }
            results.append(record)
        }
        return results
    }
    public func restore(_ original: TransferRecord, allowedRoots: [URL], token: CancellationToken, collision: @escaping CollisionHandler, progress: @escaping Progress = { _ in }) async throws -> TransferRecord {
        await gate.acquire()
        do {
            let record = try await restoreUnlocked(original, allowedRoots: allowedRoots, token: token, collision: collision, progress: progress)
            await gate.release(); return record
        } catch { await gate.release(); throw error }
    }
    private func restoreUnlocked(_ original: TransferRecord, allowedRoots: [URL], token: CancellationToken, collision: @escaping CollisionHandler, progress: @escaping Progress) async throws -> TransferRecord {
        guard original.canRestore, let expected = original.snapshot else { throw PathBoardError.unsafe("この履歴は取り戻せません。") }
        // Check the persisted record, not just a stale UI copy.
        guard let persisted = try persistence.records().first(where: { $0.id == original.id }), persisted.canRestore else { throw PathBoardError.unsafe("すでに取り戻した項目です。") }
        let sourceRoot = URL(fileURLWithPath: original.sourceRoot), destinationRoot = URL(fileURLWithPath: original.destinationRoot)
        let approved = Set(allowedRoots.map { $0.standardizedFileURL.path })
        guard approved.contains(sourceRoot.path), approved.contains(destinationRoot.path) else { throw PathBoardError.unsafe("元と先の保存先をパネルへ再登録してください。") }
        let item = URL(fileURLWithPath: original.destination)
        try FileSafety.validate(item, inside: destinationRoot)
        guard expected == (try FileSafety.snapshot(item, token: token)) else { throw PathBoardError.changed }
        var updated = original
        if original.operation == .copy {
            try coordinated(source: item, destination: item.deletingLastPathComponent()) { a, _ in
                try FileSafety.validate(a, inside: destinationRoot)
                guard expected == (try FileSafety.snapshot(a, token: token)) else { throw PathBoardError.changed }
                updated.message = "コピーの取り消しを開始しました。"; updated.phase = .needsReview
                try publish(updated, progress: progress); try token.check()
                _ = try trash(a)
                updated.phase = .restored; updated.message = "コピーをゴミ箱へ移しました。"
                try publish(updated, progress: progress)
            }
        } else {
            let parent = URL(fileURLWithPath: original.source).deletingLastPathComponent()
            try FileSafety.validate(parent, inside: sourceRoot, allowRoot: true)
            guard FileSafety.exists(parent) else { throw PathBoardError.unsafe("元の親フォルダがありません。") }
            // Persist the intent before the inverse operation: never retry ambiguously after a crash.
            updated.phase = .needsReview; updated.message = "取り戻しを開始しました。"
            try publish(updated, progress: progress)
            let request = TransferRequest(sources: [item], sourceRoot: destinationRoot, destinationFolder: parent, destinationRoot: sourceRoot, operation: .move)
            // Preserve the original filename even if the forward operation renamed it.
            let records = await executeUnlocked(request, token: token, collision: collision, progress: progress, parentID: original.id, destinationName: URL(fileURLWithPath: original.source).lastPathComponent, expectedSnapshot: expected)
            guard let restored = records.first, restored.phase == .completed else {
                if let result = records.first, [.skipped, .cancelled].contains(result.phase), result.snapshot == nil,
                   expected == (try? FileSafety.snapshot(item)) {
                    updated.phase = .completed
                    updated.message = "取り戻しは未実行です。履歴から再度実行できます。"
                } else { updated.message = "取り戻しは完了していません。処理履歴を確認してください。" }
                try publish(updated, progress: progress); return updated
            }
            updated.phase = .restored
            updated.message = restored.destination == original.source ? "元の場所へ取り戻しました。" : "別名で取り戻しました：" + URL(fileURLWithPath: restored.destination).lastPathComponent
            try publish(updated, progress: progress)
        }
        return updated
    }
}
