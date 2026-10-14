import Foundation
import Darwin

public final class Persistence: @unchecked Sendable {
    public let directory: URL
    private let lock = NSRecursiveLock()
    public init(directory: URL, createDirectories: Bool = true) throws {
        self.directory = directory
        if createDirectories { try FileManager.default.createDirectory(at: directory.appendingPathComponent("History"), withIntermediateDirectories: true) }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(value)
        try bytes.write(to: url, options: .atomic)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PathBoardError.history("履歴の保存確認に失敗しました。") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw PathBoardError.history("履歴をディスクへ保存できませんでした。") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { defer { close(parent) }; guard fsync(parent) == 0 else { throw PathBoardError.history("保存先の同期に失敗しました。") } }
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    public func loadPreferences() throws -> Preferences {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent("Preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Preferences() }
        return try read(Preferences.self, at: url)
    }
    public func savePreferences(_ value: Preferences) throws {
        lock.lock(); defer { lock.unlock() }
        try write(value, to: directory.appendingPathComponent("Preferences.json"))
    }
    public func save(_ record: TransferRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try write(record, to: directory.appendingPathComponent("History/\(record.id.uuidString).json"))
    }
    public func records() throws -> [TransferRecord] {
        lock.lock(); defer { lock.unlock() }
        let urls = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("History"), includingPropertiesForKeys: nil)
        return try urls.filter { $0.pathExtension == "json" }.map { try read(TransferRecord.self, at: $0) }.sorted { $0.date > $1.date }
    }
    public func clearHistory() throws {
        lock.lock(); defer { lock.unlock() }
        for record in try records() {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("History/\(record.id.uuidString).json"))
        }
    }
}
