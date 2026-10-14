import Foundation
import CryptoKit
import Darwin

public enum FileSafety {
    private static func comparisonPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func sameLocation(_ first: URL, _ second: URL) -> Bool {
        comparisonPath(first) == comparisonPath(second)
    }
    public static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = comparisonPath(candidate), ancestorPath = comparisonPath(ancestor)
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/")
    }
    public static func exists(_ url: URL) -> Bool {
        var st = stat(); return lstat(url.path, &st) == 0
    }
    public static func identity(_ url: URL) throws -> String {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return "\(st.st_dev):\(st.st_ino)"
    }
    public static func validate(_ url: URL, inside root: URL, allowRoot: Bool = false) throws {
        let base = root.standardizedFileURL
        let path = url.standardizedFileURL
        guard (allowRoot && path.path == base.path) || path.path.hasPrefix(base.path + "/") else {
            throw PathBoardError.unsafe("登録した保存先の外を操作することはできません。")
        }
        guard base.resolvingSymlinksInPath().path == base.path else { throw PathBoardError.unsafe("保存先の参照が変わりました。再登録してください。") }
        var current = path
        while current.path != base.path {
            var st = stat()
            if lstat(current.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
                throw PathBoardError.unsupported("シンボリックリンクを経由する操作は対象外です。")
            }
            current.deleteLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathBoardError.unsafe("保存先が利用できません。")
        }
    }
    public static func normalizedSources(_ sources: [URL]) -> [URL] {
        let unique = Array(Set(sources.map { $0.standardizedFileURL.path })).sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in unique where !kept.contains(where: { path.hasPrefix($0 + "/") }) { kept.append(path) }
        return kept.map { URL(fileURLWithPath: $0) }
    }
    public static func availableName(_ desired: URL, isDirectory: Bool? = nil) -> URL {
        if !exists(desired) { return desired }
        var dir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: desired.path, isDirectory: &dir)
        let ext = (isDirectory ?? dir.boolValue) ? "" : desired.pathExtension
        let stem = ext.isEmpty ? desired.lastPathComponent : desired.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let name = "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = desired.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(candidate) { return candidate }; index += 1
        }
    }
    public static func renameExclusively(_ from: URL, to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    private static func userAttributes(_ url: URL) throws -> [String: String] {
        let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if count == 0 { return [:] }
        var buffer = [CChar](repeating: 0, count: count)
        let read = listxattr(url.path, &buffer, count, XATTR_NOFOLLOW)
        guard read >= 0 else { throw PathBoardError.changed }
        let names = buffer.prefix(read).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var result: [String: String] = [:]
        for name in names where name == "com.apple.FinderInfo" || name == "com.apple.ResourceFork" || name.hasPrefix("com.apple.metadata:") || name.hasPrefix("user.") {
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw PathBoardError.changed }
            guard size <= 16 * 1024 * 1024 else { throw PathBoardError.unsupported("16MiBを超えるユーザー属性は初期版の対象外です。") }
            var bytes = [UInt8](repeating: 0, count: size)
            let read = getxattr(url.path, name, &bytes, size, 0, XATTR_NOFOLLOW)
            guard read == size else { throw PathBoardError.changed }
            result[name] = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    public static func snapshot(_ url: URL, token: CancellationToken = CancellationToken()) throws -> Snapshot {
        let rootIdentity = try identity(url)
        var entries: [ManifestEntry] = []
        func visit(_ item: URL, relative: String) throws {
            try token.check()
            var st = stat()
            guard lstat(item.path, &st) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { throw PathBoardError.unsupported("リンク・特殊ファイルを含む項目は対象外です。") }
            guard kind != S_IFREG || st.st_nlink == 1 else { throw PathBoardError.unsupported("ハードリンクは対象外です。") }
            if try kind == S_IFDIR && item.resourceValues(forKeys: [.isPackageKey]).isPackage == true {
                throw PathBoardError.unsupported("パッケージは初期版の転送対象外です。")
            }
            var digest = ""
            if kind == S_IFREG {
                let fd = open(item.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_ino == st.st_ino, opened.st_dev == st.st_dev else { throw PathBoardError.changed }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try token.check(); hasher.update(data: data) }
                var after = stat(); guard fstat(fd, &after) == 0, after.st_size == st.st_size, after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec else { throw PathBoardError.changed }
                digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            let attrs = try userAttributes(item)
            entries.append(ManifestEntry(path: relative, directory: kind == S_IFDIR, size: kind == S_IFDIR ? 0 : UInt64(st.st_size), digest: digest, mode: UInt16(st.st_mode & 0o777), modified: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, attributes: attrs))
            if kind == S_IFDIR {
                let children = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent) }
            }
        }
        try visit(url, relative: "")
        guard try identity(url) == rootIdentity else { throw PathBoardError.changed }
        return Snapshot(entries: entries, identity: rootIdentity)
    }
}
