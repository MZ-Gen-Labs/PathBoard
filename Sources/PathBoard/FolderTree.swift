import SwiftUI
import AppKit
import PathBoardCore

struct DragPayload: Codable { let panelID: UUID; let paths: [String] }
private let dragType = NSPasteboard.PasteboardType("app.pathboard.internal-items")

final class TreeNode: NSObject {
    let url: URL
    let directory: Bool
    let browsable: Bool
    var children: [TreeNode]?
    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        directory = values?.isDirectory == true
        browsable = directory && values?.isSymbolicLink != true && values?.isPackage != true
    }
}
struct FolderTree: NSViewRepresentable {
    let panel: PanelConfiguration
    let refreshID: UUID
    let onChange: (String, String?, [String], Double) -> Void
    let onDrop: (DragPayload, URL) -> Void
    let onError: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.update(self) }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var owner: FolderTree
        let outline = NSOutlineView()
        let scroll = NSScrollView()
        var root: TreeNode?
        var nodes: [String: TreeNode] = [:]
        var loadedKey = ""
        var refreshing = false
        var restoring = false
        var generation = UUID()
        var observer: NSObjectProtocol?
        var currentURL: URL?
        var selectedURL: URL?
        init(_ owner: FolderTree) { self.owner = owner }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func makeView() -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.title = "名前"; column.width = 350
            outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
            outline.delegate = self; outline.dataSource = self; outline.rowHeight = 26; outline.allowsMultipleSelection = true
            outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle; outline.autoresizingMask = [.width]
            outline.registerForDraggedTypes([dragType]); outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
            outline.setDraggingSourceOperationMask([], forLocal: false)
            scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.persistState() }
            update(owner); return scroll
        }
        func update(_ value: FolderTree) {
            owner = value
            let key = "\(value.panel.id):\(value.panel.rootPath ?? ""):\(value.panel.showsHidden):\(value.refreshID)"
            guard key != loadedKey else { return }; loadedKey = key; generation = UUID()
            currentURL = value.panel.root.map { $0.appendingPathComponent(value.panel.currentPath) }
            selectedURL = value.panel.selectedPath.map { URL(fileURLWithPath: $0) }
            if let rootURL = value.panel.root {
                var current = currentURL ?? rootURL
                while !FileSafety.exists(current), current.path != rootURL.path { current.deleteLastPathComponent() }
                currentURL = current
            }
            if selectedURL == nil { selectedURL = currentURL }
            nodes.removeAll(); root = value.panel.root.map { TreeNode(url: $0) }; refreshing = true
            outline.reloadData(); if let root { load(root) } else { refreshing = false }
        }
        func load(_ node: TreeNode) {
            guard node.browsable, node.children == nil else { return }
            node.children = []
            let expectedGeneration = generation, showHidden = owner.panel.showsHidden
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try FileManager.default.contentsOfDirectory(at: node.url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: showHidden ? [] : [.skipsHiddenFiles]).map { TreeNode(url: $0) }.sorted {
                    if $0.directory != $1.directory { return $0.directory }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                } }
                DispatchQueue.main.async {
                    guard let self, self.generation == expectedGeneration else { return }
                    switch result {
                    case .success(let children):
                        self.owner.onError(nil)
                        node.children = children; for child in children { self.nodes[child.url.path] = child }
                        self.restoring = true
                        self.outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
                        for child in children where self.owner.panel.expandedPaths.contains(child.url.path) && child.browsable { self.outline.expandItem(child); self.load(child) }
                        if let url = self.selectedURL ?? self.currentURL, let selected = self.nodes[url.path] { let row = self.outline.row(forItem: selected); if row >= 0 { self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } }
                        self.scroll.contentView.scroll(to: NSPoint(x: 0, y: self.owner.panel.scrollY)); self.scroll.reflectScrolledClipView(self.scroll.contentView)
                        self.restoring = false; self.refreshing = false
                    case .failure(let error):
                        self.owner.onError(error.localizedDescription)
                        self.refreshing = false
                        self.outline.backgroundColor = .windowBackgroundColor
                        self.outline.toolTip = "フォルダを読み込めません。権限・接続を確認して再読み込みしてください。"
                    }
                    self.persistState()
                }
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? TreeNode ?? root)?.children?.count ?? 0 }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? TreeNode ?? root)!.children![index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? TreeNode)?.browsable == true }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? TreeNode else { return nil }
            let view = NSTableCellView(); let text = NSTextField(labelWithString: node.url.lastPathComponent)
            text.lineBreakMode = .byTruncatingMiddle; text.translatesAutoresizingMaskIntoConstraints = false
            let image = NSImageView(); image.image = NSWorkspace.shared.icon(forFile: node.url.path); image.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(image); view.addSubview(text); view.textField = text; view.imageView = image; view.toolTip = node.url.path
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3), image.centerYAnchor.constraint(equalTo: view.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        }
        func outlineViewItemDidExpand(_ notification: Notification) { if let node = notification.userInfo?["NSObject"] as? TreeNode { load(node) }; persistState() }
        func outlineViewItemDidCollapse(_ notification: Notification) { persistState() }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !restoring, outline.selectedRow >= 0, let selected = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
            currentURL = selected.browsable ? selected.url : selected.url.deletingLastPathComponent(); selectedURL = selected.url; persistState()
        }
        func persistState() {
            guard !restoring, !refreshing, let base = owner.panel.root, let currentURL else { return }
            let relative = currentURL.path == base.path ? "" : String(currentURL.path.dropFirst(base.path.count + 1))
            var expanded = Set(owner.panel.expandedPaths)
            for node in nodes.values where node.browsable {
                if outline.isItemExpanded(node) { expanded.insert(node.url.path) }
                else if outline.row(forItem: node) >= 0 { expanded.remove(node.url.path) }
            }
            owner.onChange(relative, selectedURL?.path, expanded.sorted(), scroll.contentView.bounds.origin.y)
        }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? TreeNode else { return nil }
            let paths = outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? TreeNode)?.url.path }
            let payload = DragPayload(panelID: owner.panel.id, paths: paths.isEmpty ? [node.url.path] : paths)
            guard let data = try? JSONEncoder().encode(payload) else { return nil }
            let writer = NSPasteboardItem(); writer.setData(data, forType: dragType); return writer
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard info.draggingSource != nil, let data = info.draggingPasteboard.data(forType: dragType), let payload = try? JSONDecoder().decode(DragPayload.self, from: data) else { return [] }
            if let node = item as? TreeNode {
                guard node.browsable else { return [] }; outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else { outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            if payload.panelID == owner.panel.id, let root = owner.panel.root {
                let destination = (item as? TreeNode)?.url ?? currentURL ?? root
                guard (try? FileSafety.validate(destination, inside: root, allowRoot: true)) != nil else { return [] }
                for source in FileSafety.normalizedSources(payload.paths.map { URL(fileURLWithPath: $0) }) {
                    guard (try? FileSafety.validate(source, inside: root)) != nil,
                          !FileSafety.sameLocation(source.deletingLastPathComponent(), destination),
                          !FileSafety.isSameOrDescendant(destination, of: source) else { return [] }
                }
            }
            return .copy
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let data = info.draggingPasteboard.data(forType: dragType), let payload = try? JSONDecoder().decode(DragPayload.self, from: data),
                  let folder = (item as? TreeNode)?.url ?? currentURL ?? owner.panel.root else { return false }
            // NSOutlineView may request the same payload for every selected row.
            owner.onDrop(DragPayload(panelID: payload.panelID, paths: Array(Set(payload.paths))), folder); return true
        }
    }
}
