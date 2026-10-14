import Foundation

public struct PanelConfiguration: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var rootPath: String?
    public var bookmark: Data?
    public var name = "保存先を追加"
    public var currentPath = ""
    public var selectedPath: String?
    public var expandedPaths: [String] = []
    public var scrollY: Double = 0
    public var showsHidden = false
    public init() {}
    public var root: URL? { rootPath.map { URL(fileURLWithPath: $0) } }
}
public struct Workspace: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var panels = (0..<4).map { _ in PanelConfiguration() }
    public var horizontalRatio = 0.5
    public var verticalRatio = 0.5
    public init(name: String) { self.name = name }
}
public struct Preferences: Codable {
    public var workspaces = [Workspace(name: "メイン")]
    public var selectedID: UUID?
    public init() { selectedID = workspaces[0].id }
}
public enum TransferOperation: String, Codable { case copy, move }
public enum CollisionChoice: String, Codable { case rename, skip, cancel }
public enum TransferPhase: String, Codable {
    case preparing, copying, verifying, committed, removingSource, completed, failed, needsReview, cancelled, skipped, restored
    public var label: String {
        switch self {
        case .preparing: return "準備中"
        case .copying: return "取得待ち・コピー中"
        case .verifying: return "検証中"
        case .committed: return "コピー済み"
        case .removingSource: return "元データ保全中"
        case .completed: return "Mac上の処理完了"
        case .failed: return "失敗"
        case .needsReview: return "要確認"
        case .cancelled: return "中断"
        case .skipped: return "スキップ"
        case .restored: return "取り戻し済み"
        }
    }
}
public struct ManifestEntry: Codable, Equatable {
    public let path: String
    public let directory: Bool
    public let size: UInt64
    public let digest: String
    public let mode: UInt16
    public let modified: Double
    public let attributes: [String: String]
}
public struct Snapshot: Codable, Equatable {
    public let entries: [ManifestEntry]
    public let identity: String
    public func sameContent(as other: Snapshot) -> Bool { entries == other.entries }
}
public struct TransferRecord: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var operation: TransferOperation
    public var source: String
    public var destination: String
    public var sourceRoot: String
    public var destinationRoot: String
    public var phase: TransferPhase = .preparing
    public var message = ""
    public var snapshot: Snapshot?
    public var retainedSource: String?
    public var temporaryPath: String?
    public var parentRecordID: UUID?
    public init(operation: TransferOperation, source: URL, destination: URL, sourceRoot: URL, destinationRoot: URL) {
        self.operation = operation; self.source = source.path; self.destination = destination.path
        self.sourceRoot = sourceRoot.path; self.destinationRoot = destinationRoot.path
    }
    public var canRestore: Bool { phase == .completed && snapshot != nil && parentRecordID == nil }
}
public struct TransferRequest {
    public let sources: [URL]
    public let sourceRoot: URL
    public let destinationFolder: URL
    public let destinationRoot: URL
    public let operation: TransferOperation
    public init(sources: [URL], sourceRoot: URL, destinationFolder: URL, destinationRoot: URL, operation: TransferOperation) {
        self.sources = sources; self.sourceRoot = sourceRoot; self.destinationFolder = destinationFolder
        self.destinationRoot = destinationRoot; self.operation = operation
    }
}
public enum PathBoardError: LocalizedError {
    case unsafe(String), changed, cancelled, unsupported(String), history(String)
    public var errorDescription: String? {
        switch self {
        case .unsafe(let s), .unsupported(let s), .history(let s): return s
        case .changed: return "内容または属性が変更されたため処理を止めました。元データは自動削除しません。"
        case .cancelled: return "キャンセルしました。"
        }
    }
}
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func check() throws { if isCancelled { throw PathBoardError.cancelled } }
}
