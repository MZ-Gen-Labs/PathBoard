import AppKit
import SwiftUI
import PathBoardCore

@MainActor final class AppStore: ObservableObject {
    @Published var preferences: Preferences
    @Published var records: [TransferRecord] = []
    @Published var running = false
    @Published var queuedCount = 0
    @Published var currentStatus = "準備できました"
    @Published var historyVisible = false
    @Published var refreshID = UUID()
    @Published var errorMessage: String?
    let persistence: Persistence
    let engine: TransferEngine
    private var token: CancellationToken?
    private var jobs: [Job] = []
    private var saveTask: Task<Void, Never>?
    private var settingsWritable = true
    private var operationsAvailable = true
    enum Job { case transfer(TransferRequest), restore(TransferRecord, [URL]) }
    var workspaceIndex: Int { preferences.workspaces.firstIndex { $0.id == preferences.selectedID } ?? 0 }
    var workspace: Workspace { preferences.workspaces[workspaceIndex] }
    init() {
        let path = ProcessInfo.processInfo.environment["PATHBOARD_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PathBoard")
        var startupFailure: String?
        do { persistence = try Persistence(directory: path) }
        catch {
            persistence = try! Persistence(directory: path, createDirectories: false)
            startupFailure = "設定保存先を開けないため、ファイル操作を停止しています：" + error.localizedDescription
        }
        engine = TransferEngine(persistence: persistence)
        preferences = Preferences()
        do {
            let loaded = try persistence.loadPreferences()
            guard !loaded.workspaces.isEmpty, loaded.workspaces.allSatisfy({ $0.panels.count == 4 && $0.horizontalRatio.isFinite && $0.verticalRatio.isFinite }), Set(loaded.workspaces.map(\.id)).count == loaded.workspaces.count else { throw PathBoardError.history("設定の構造が不正です。") }
            preferences = loaded
            for w in preferences.workspaces.indices {
                for i in 0..<4 {
                    if let bookmark = preferences.workspaces[w].panels[i].bookmark {
                        var stale = false
                        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                            preferences.workspaces[w].panels[i].rootPath = url.resolvingSymlinksInPath().path
                        }
                    }
                }
            }
        } catch {
            settingsWritable = false; operationsAvailable = false
            errorMessage = "設定を読み込めません。元の設定は保存したままです。アプリ終了後、Preferences.jsonを別名にして再起動してください。\n" + error.localizedDescription
        }
        reloadRecords()
        if let startupFailure { settingsWritable = false; operationsAvailable = false; errorMessage = startupFailure }
    }
    func updatePanel(_ index: Int, _ change: (inout PanelConfiguration) -> Void) {
        guard preferences.workspaces[workspaceIndex].panels.indices.contains(index) else { return }
        change(&preferences.workspaces[workspaceIndex].panels[index]); scheduleSave()
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { saveNow() } }
    }
    func saveNow() {
        guard settingsWritable else { return }
        do { try persistence.savePreferences(preferences) } catch { errorMessage = "設定を保存できません：" + error.localizedDescription }
    }
    func resetDamagedSettings() {
        guard !running, confirm("設定を初期化しますか？", detail: "現在の設定ファイルを別名で保管します。保存先の実データは変更しません。", action: "初期化") else { return }
        let source = persistence.directory.appendingPathComponent("Preferences.json")
        do {
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: persistence.directory.appendingPathComponent("Preferences-damaged-\(UUID().uuidString).json")) }
            preferences = Preferences(); settingsWritable = true; operationsAvailable = true; saveNow(); reloadRecords(); refreshID = UUID()
        } catch { errorMessage = error.localizedDescription }
    }
    func register(_ index: Int) {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.message = "保存先フォルダを選んでください。Vaultも通常のフォルダとして扱います。"
        guard picker.runModal() == .OK, let chosen = picker.url else { return }
        let url = chosen.resolvingSymlinksInPath().standardizedFileURL
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            updatePanel(index) { panel in
                panel.rootPath = url.path; panel.bookmark = bookmark; panel.name = url.lastPathComponent
                panel.currentPath = ""; panel.expandedPaths = []; panel.scrollY = 0
            }
            saveNow(); refreshID = UUID()
        } catch { errorMessage = error.localizedDescription }
    }
    func prompt(_ title: String, value: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 300, height: 26); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    func renamePanel(_ index: Int) { if let name = prompt("保存先の表示名", value: workspace.panels[index].name) { updatePanel(index) { $0.name = name }; saveNow() } }
    func removePanel(_ index: Int) { updatePanel(index) { $0 = PanelConfiguration() }; saveNow(); refreshID = UUID() }
    func saveWorkspaceAs() {
        guard let name = prompt("ワークスペースを保存", value: workspace.name) else { return }
        var copy = workspace
        if let existing = preferences.workspaces.firstIndex(where: { $0.name == name }) {
            guard confirm("「\(name)」を更新しますか？", detail: "フォルダ内のファイルは変更しません。", action: "更新") else { return }
            copy.id = preferences.workspaces[existing].id; copy.name = name; preferences.workspaces[existing] = copy
        } else { copy.id = UUID(); copy.name = name; preferences.workspaces.append(copy) }
        preferences.selectedID = copy.id; saveNow()
    }
    func renameWorkspace() {
        guard let name = prompt("ワークスペース名", value: workspace.name) else { return }
        guard !preferences.workspaces.contains(where: { $0.name == name && $0.id != workspace.id }) else { errorMessage = "同じ名前がすでに存在します。"; return }
        preferences.workspaces[workspaceIndex].name = name; saveNow()
    }
    func deleteWorkspace() {
        guard preferences.workspaces.count > 1, confirm("ワークスペースを削除しますか？", detail: "保存先のファイルは削除しません。", action: "削除") else { return }
        preferences.workspaces.remove(at: workspaceIndex); preferences.selectedID = preferences.workspaces[0].id; saveNow(); refreshID = UUID()
    }
    func selectWorkspace(_ id: UUID) { saveNow(); preferences.selectedID = id; saveNow(); refreshID = UUID() }
    func confirm(_ title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action); alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func acceptDrop(payload: DragPayload, into index: Int, folder: URL) {
        guard operationsAvailable else { errorMessage = "設定・履歴の読み書きに問題があるため、ファイル操作を停止しています。"; return }
        guard let sourceIndex = workspace.panels.firstIndex(where: { $0.id == payload.panelID }), sourceIndex != index,
              let sourceRoot = workspace.panels[sourceIndex].root, let destinationRoot = workspace.panels[index].root else { return }
        let alert = NSAlert(); alert.messageText = "\(payload.paths.count)項目を転送"
        alert.informativeText = "保存先：\(folder.path)\n\n移動はコピー検証後に元データをゴミ箱へ保全します。クラウド同期の完了は確認できません。"
        alert.addButton(withTitle: "コピー"); alert.addButton(withTitle: "移動"); alert.addButton(withTitle: "キャンセル")
        let response = alert.runModal(); guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let request = TransferRequest(sources: payload.paths.map { URL(fileURLWithPath: $0) }, sourceRoot: sourceRoot, destinationFolder: folder, destinationRoot: destinationRoot, operation: response == .alertFirstButtonReturn ? .copy : .move)
        jobs.append(.transfer(request)); queuedCount = jobs.count; startNext()
    }
    func receive(_ record: TransferRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record } else { records.insert(record, at: 0) }
        currentStatus = record.phase.label + "：" + URL(fileURLWithPath: record.source).lastPathComponent
    }
    func startNext() {
        guard !running, !jobs.isEmpty else { return }
        let job = jobs.removeFirst(); queuedCount = jobs.count; running = true
        let cancellation = CancellationToken(); token = cancellation
        let engine = self.engine
        let collision: TransferEngine.CollisionHandler = { url in await MainActor.run {
            let alert = NSAlert(); alert.messageText = "同名項目があります"
            alert.informativeText = url.lastPathComponent + "\n既存項目は上書きしません。"
            alert.addButton(withTitle: "別名で保存"); alert.addButton(withTitle: "スキップ"); alert.addButton(withTitle: "キャンセル")
            switch alert.runModal() { case .alertFirstButtonReturn: return .rename; case .alertSecondButtonReturn: return .skip; default: return .cancel }
        } }
        let progress: TransferEngine.Progress = { [weak self] record in Task { @MainActor in self?.receive(record) } }
        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> String? in
                switch job {
                case .transfer(let request): _ = await engine.execute(request, token: cancellation, collision: collision, progress: progress); return nil
                case .restore(let record, let roots):
                    do { _ = try await engine.restore(record, allowedRoots: roots, token: cancellation, collision: collision, progress: progress); return nil }
                    catch { return error.localizedDescription }
                }
            }.value
            running = false; token = nil; reloadRecords(); refreshID = UUID()
            if let message { errorMessage = message }
            if jobs.isEmpty { currentStatus = "処理終了。詳細は履歴を確認してください。" }; startNext()
        }
    }
    func cancel() { token?.cancel(); jobs.removeAll(); queuedCount = 0; currentStatus = "キャンセル要求を受け付けました。処理結果を確認中…" }
    func restore(_ record: TransferRecord) {
        guard operationsAvailable else { errorMessage = "設定・履歴の問題を解決してから取り戻してください。"; return }
        let detail = record.operation == .move ? "未変更の移動先から元の場所へ戻します。同名項目は上書きしません。" : "この操作で作成した未変更のコピーをゴミ箱へ移します。"
        guard confirm("この操作を取り戻しますか？", detail: detail, action: "取り戻す") else { return }
        let roots = preferences.workspaces.flatMap { $0.panels.compactMap(\.root) }
        jobs.append(.restore(record, roots)); queuedCount = jobs.count; startNext()
    }
    func reloadRecords() {
        do {
            records = try persistence.records()
            if !running {
                for i in records.indices where [.preparing, .copying, .verifying, .committed, .removingSource].contains(records[i].phase) {
                    records[i].phase = .needsReview
                    records[i].message = "前回の処理が中断しています。元・先・ゴミ箱を確認してください。自動再実行はしません。"
                }
            }
        }
        catch { operationsAvailable = false; errorMessage = "履歴を読み込めません。元の履歴は保存したままです。\n" + error.localizedDescription }
    }
    func clearHistory() {
        guard !running, confirm("履歴だけを削除しますか？", detail: "ファイルは変更しません。履歴から取り戻すための情報が失われます。", action: "履歴を削除") else { return }
        do { try persistence.clearHistory(); reloadRecords() } catch { errorMessage = error.localizedDescription }
    }
}
