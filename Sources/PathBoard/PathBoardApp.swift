import SwiftUI
import AppKit
import PathBoardCore

@main struct PathBoardApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("PathBoard") {
            ContentView().environmentObject(store).frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }.defaultSize(width: 1200, height: 800)
        .commands { CommandGroup(replacing: .newItem) { Button("ワークスペースを保存…") { store.saveWorkspaceAs() }.keyboardShortcut("s"); Button("設定の復旧・初期化…") { store.resetDamagedSettings() } }; CommandGroup(after: .toolbar) { Button("再読み込み") { store.refreshID = UUID() }.keyboardShortcut("r"); Button("処理履歴") { store.historyVisible = true }.keyboardShortcut("h", modifiers: [.command, .shift]) } }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.saveNow()
        if store?.running == true {
            let alert = NSAlert(); alert.messageText = "処理中です"; alert.informativeText = "キャンセルし、処理が終了してからアプリを閉じてください。"
            alert.addButton(withTitle: "処理をキャンセル"); alert.addButton(withTitle: "戻る")
            if alert.runModal() == .alertFirstButtonReturn { store?.cancel() }; return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct ContentView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill").foregroundStyle(.tint)
                Text("PathBoard").font(.title3.bold())
                Picker("ワークスペース", selection: Binding(get: { store.workspace.id }, set: { store.selectWorkspace($0) })) {
                    ForEach(store.preferences.workspaces) { Text($0.name).tag($0.id) }
                }.frame(width: 230)
                Menu { Button("名前を付けて保存…") { store.saveWorkspaceAs() }; Button("名前変更…") { store.renameWorkspace() }; Button("削除…") { store.deleteWorkspace() }.disabled(store.preferences.workspaces.count == 1) } label: { Image(systemName: "ellipsis.circle") }
                Spacer()
                Button { store.refreshID = UUID() } label: { Label("再読み込み", systemImage: "arrow.clockwise") }
                Button { store.historyVisible = true } label: { Label("履歴", systemImage: "clock.arrow.circlepath") }
            }.padding(14)
            Divider()
            GeometryReader { geometry in
                let h = min(0.75, max(0.25, store.workspace.horizontalRatio))
                let v = min(0.75, max(0.25, store.workspace.verticalRatio))
                let width = geometry.size.width - 6, height = geometry.size.height - 6
                VStack(spacing: 0) {
                    HStack(spacing: 0) { PanelView(index: 0).frame(width: width * h); verticalDivider(geometry.size.width); PanelView(index: 1).frame(width: width * (1-h)) }.frame(height: height * v)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 6).onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }.gesture(DragGesture(coordinateSpace: .named("grid")).onChanged { value in store.preferences.workspaces[store.workspaceIndex].verticalRatio = min(0.75, max(0.25, value.location.y / geometry.size.height)); store.scheduleSave() })
                    HStack(spacing: 0) { PanelView(index: 2).frame(width: width * h); verticalDivider(geometry.size.width); PanelView(index: 3).frame(width: width * (1-h)) }.frame(height: height * (1-v))
                }.coordinateSpace(name: "grid")
            }
            Divider()
            HStack {
                if store.running { ProgressView().controlSize(.small) }
                Text(store.currentStatus).font(.caption).lineLimit(1)
                Spacer()
                if store.queuedCount > 0 { Text("待機 \(store.queuedCount)件").font(.caption) }
                if store.running { Button("キャンセル") { store.cancel() }.controlSize(.small) }
                Text("Mac上の処理のみ・クラウド同期は未確認").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .sheet(isPresented: $store.historyVisible) { HistoryView().environmentObject(store) }
        .alert("PathBoard", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    func verticalDivider(_ total: Double) -> some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 6)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(coordinateSpace: .named("grid")).onChanged { value in store.preferences.workspaces[store.workspaceIndex].horizontalRatio = min(0.75, max(0.25, value.location.x / total)); store.scheduleSave() })
    }
}
struct PanelView: View {
    @EnvironmentObject var store: AppStore
    let index: Int
    @State private var treeError: String?
    var panel: PanelConfiguration { store.workspace.panels[index] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = panel.root {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(panel.name).font(.headline).lineLimit(1)
                    Spacer()
                    Menu { Button("表示名を変更…") { store.renamePanel(index) }; Button("保存先を再指定…") { store.register(index) }; Toggle("隠し項目を表示", isOn: Binding(get: { panel.showsHidden }, set: { value in store.updatePanel(index) { $0.showsHidden = value } })); Button("登録を外す") { store.removePanel(index) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
                }.padding(.horizontal, 12).padding(.top, 10)
                let current = root.appendingPathComponent(panel.currentPath).path
                HStack {
                    Text(panel.currentPath.isEmpty ? root.path : root.lastPathComponent + "/" + panel.currentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(current)
                    Spacer(minLength: 2)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("現在のパスをコピー")
                    Button { store.updatePanel(index) { $0.currentPath = "" }; store.refreshID = UUID() } label: { Image(systemName: "house") }.buttonStyle(.plain).help("登録したルートへ戻る")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                if FileSafety.exists(root) {
                    if let treeError { Text("フォルダを読み込めません：" + treeError).font(.caption).foregroundStyle(.orange).padding(8) }
                    FolderTree(panel: panel, refreshID: store.refreshID, onChange: { current, expanded, scroll in
                        guard current != panel.currentPath || expanded != panel.expandedPaths || abs(scroll-panel.scrollY) > 1 else { return }
                        store.updatePanel(index) { $0.currentPath = current; $0.expandedPaths = expanded; $0.scrollY = scroll }
                    }, onDrop: { payload, folder in store.acceptDrop(payload: payload, into: index, folder: folder) }, onError: { treeError = $0 })
                } else {
                    ContentUnavailableView { Label("保存先が利用できません", systemImage: "exclamationmark.folder") } description: { Text("接続・権限を確認するか、保存先を再指定してください。") } actions: { Button("再指定") { store.register(index) } }
                }
            } else {
                Spacer()
                VStack(spacing: 12) { Image(systemName: "folder.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary); Text("保存先を追加").font(.headline); Text("フォルダやObsidian Vaultを登録").font(.caption).foregroundStyle(.secondary); Button("フォルダを選択…") { store.register(index) } }
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }
}
struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("処理履歴と取り戻し").font(.title2.bold()); Spacer(); Button("閉じる") { store.historyVisible = false }.keyboardShortcut(.cancelAction) }
            Text("取り戻しは未変更の項目が対象です。外部で変更・削除されたデータの復旧を保証するバックアップではありません。").font(.caption).foregroundStyle(.secondary)
            List(store.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(record.operation == .move ? "移動" : "コピー").font(.headline); Text(record.phase.label).foregroundStyle(record.phase == .completed || record.phase == .restored ? .green : .secondary); Spacer(); Text(record.date, style: .date).font(.caption); if record.canRestore { Button("取り戻す") { store.restore(record) }.disabled(store.running) } }
                    Text(record.source + " → " + record.destination).font(.caption).textSelection(.enabled)
                    if !record.message.isEmpty { Text(record.message).font(.caption).foregroundStyle(.secondary) }; if let temporary = record.temporaryPath { Text("一時項目（残っている場合は要確認）：" + temporary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(.vertical, 5)
            }
            HStack { Button("履歴だけを削除…") { store.clearHistory() }.disabled(store.running); Spacer(); Text("進行中の履歴は再起動後も自動再実行しません。").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(minWidth: 800, minHeight: 500)
    }
}
