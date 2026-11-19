import AppKit
import Quartz

final class FileNode: NSObject {
    /// 숨김 파일(.git, .env …) 표시 — 기본 켬, 눈 아이콘으로 전환 (앱 재시작해도 유지)
    static var showHidden: Bool {
        get { UserDefaults.standard.object(forKey: "showHidden") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showHidden") }
    }
    let url: URL
    let isDir: Bool
    private var kids: [FileNode]?

    init(_ url: URL) {
        self.url = url
        isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var children: [FileNode] {
        if kids == nil { kids = load() }
        return kids!
    }

    private func load() -> [FileNode] {
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: FileNode.showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return list.map(FileNode.init).sorted {
            $0.isDir != $1.isDir ? $0.isDir : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// 이미 읽은 폴더만 다시 읽고, 같은 경로의 노드 객체는 재사용 (펼침 상태 유지)
    func refresh() {
        guard let old = kids else { return }
        kids = load().map { n in old.first { $0.url == n.url } ?? n }
        kids?.forEach { $0.refresh() }
    }
}

/// 탐색기 아이콘: Material Icon Theme (MIT, Resources/FileIcons) — 확장자별 컬러 아이콘
enum FileIcons {
    private static let dir = Bundle.main.resourceURL?.appendingPathComponent("FileIcons")
    private static var cache: [String: NSImage] = [:]
    private static let byExt: [String: String] = {
        var m: [String: String] = [:]
        let table: [(String, String)] = [
            ("md markdown", "markdown"), ("txt rtf", "document"), ("swift", "swift"), ("js mjs cjs", "javascript"),
            ("jsx tsx", "react"), ("ts", "typescript"), ("json", "json"), ("java", "java"), ("kt kts", "kotlin"),
            ("py", "python"), ("html htm", "html"), ("css scss less", "css"), ("yml yaml", "yaml"), ("xml plist", "xml"),
            ("sh zsh bash fish command", "console"), ("sql db sqlite", "database"), ("pdf", "pdf"),
            ("png jpg jpeg gif heic webp bmp tiff ico icns", "image"), ("svg", "svg"), ("zip gz tar tgz 7z rar dmg", "zip"),
            ("go", "go"), ("rs", "rust"), ("c h", "c"), ("cpp cc hpp mm m", "cpp"), ("doc docx hwp hwpx", "word"),
            ("ppt pptx key", "powerpoint"), ("xls xlsx csv numbers", "table"), ("vue", "vue"), ("lock", "lock"),
            ("toml", "toml"), ("ttf otf woff woff2", "font"), ("mp4 mov avi mkv webm", "video"), ("mp3 wav m4a aac flac", "audio"),
            ("log", "log"), ("env ini conf cfg properties", "settings"),
        ]
        for (exts, icon) in table { for e in exts.split(separator: " ") { m[String(e)] = icon } }
        return m
    }()

    static func name(for url: URL, isDir: Bool, open: Bool) -> String {
        if isDir { return open ? "folder-open" : "folder" }
        switch url.lastPathComponent.lowercased() {
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml": return "docker"
        case ".gitignore", ".gitattributes", ".gitmodules": return "git"
        case ".env": return "settings"
        default: return byExt[url.pathExtension.lowercased()] ?? "file"
        }
    }

    static func image(for url: URL, isDir: Bool, open: Bool) -> NSImage? {
        let n = name(for: url, isDir: isDir, open: open)
        if let i = cache[n] { return i }
        guard let u = dir?.appendingPathComponent(n + ".svg"), let i = NSImage(contentsOf: u) else {
            return NSImage(systemSymbolName: isDir ? "folder" : "doc.text", accessibilityDescription: nil) // 번들 밖 실행 시
        }
        i.size = NSSize(width: 16, height: 16)
        cache[n] = i
        return i
    }
}

/// 탐색기 트리: ⌘⌫ 휴지통으로, ⌘Z / ⌘⇧Z 되돌리기 (탐색기 전용 실행취소 기록)
final class FileOutline: NSOutlineView {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onOpenSelected: (() -> Void)?
    let fileUndo = UndoManager()
    override var undoManager: UndoManager? { fileUndo }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command), e.keyCode == 51 { onDelete?(); return } // ⌘⌫
        if e.keyCode == 36 || e.keyCode == 76 { onReturn?(); return }                 // Return = 이름 변경 (Finder 와 같음)
        if e.keyCode == 8, e.modifierFlags.contains(.option) { onCopyPath?(); return } // ⌥C / ⌥⌘C = 경로 복사
        if e.keyCode == 125, e.modifierFlags.contains(.command) { onOpenSelected?(); return } // ⌘↓ = 열기 (Finder 와 같음)
        if e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control]).isEmpty { toggleQuickLook(); return } // 스페이스 = 훑어보기
        super.keyDown(with: e)
    }
    // MARK: 훑어보기 (Quick Look) — Finder 처럼 스페이스로 열고 닫음, 열린 채 화살표로 이동
    var previewURLs: (() -> [URL])?
    private var qlItems: [URL] = []
    var quickLookVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggleQuickLook() {
        if quickLookVisible { QLPreviewPanel.shared().orderOut(nil); return }
        guard !(previewURLs?() ?? []).isEmpty else { NSSound.beep(); return }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }
    func refreshQuickLook() {
        guard quickLookVisible, QLPreviewPanel.shared().dataSource === self else { return }
        qlItems = previewURLs?() ?? []
        QLPreviewPanel.shared().reloadData()
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        qlItems = previewURLs?() ?? []
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // 메뉴의 실행 취소/복귀(nil-target)가 첫 응답자인 트리에 먼저 도달
    @objc func undo(_ sender: Any?) { fileUndo.undo() }
    @objc func redo(_ sender: Any?) { fileUndo.redo() }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return fileUndo.canUndo
        case #selector(redo(_:)): return fileUndo.canRedo
        default: return true
        }
    }
}

/// ⌘B 사이드바. 0번 탭 = 기본(자동저장) 폴더, 이후 = 추가 폴더.
final class Sidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    var onOpen: ((URL) -> Void)?
    var onOpenTerminal: ((URL) -> Void)?
    var onFoldersChanged: (() -> Void)?
    /// "기본" 탭 더블클릭 = 기본 폴더 변경
    var onChangeRoot: (() -> Void)?
    /// 휴지통으로 보내기 직전 (열린 탭 정리용 — 안 닫으면 자동저장이 파일을 다시 만듦)
    var onWillTrash: (([URL]) -> Void)?
    private(set) var roots: [FileNode]
    private var sel = 0
    private let tabs = PillTabBar()
    private let pathLabel = label("", Theme.ui(11), Theme.fgSubtle)
    private let outline = FileOutline()
    private var renaming: FileNode?
    var selectedURLs: [URL] { outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url } }
    func outlineViewSelectionDidChange(_ n: Notification) { outline.refreshQuickLook() }

    var folders: [URL] { roots.map(\.url) }

    init(folders: [URL]) {
        roots = folders.map(FileNode.init)
        super.init(frame: .zero)
        style(bg: Theme.sunken)

        // 폴더 탭 줄: [기본][추가 폴더…][+]  — 탭은 내용 너비만큼, + 는 마지막 탭 바로 뒤
        let addBtn = IconButton("plus", "탐색기에 폴더 탭 추가 (⌘⇧O)", self, #selector(addFolder), size: 24, point: 12)
        let tabRow = NSStackView(views: [tabs, addBtn, spacer()])
        tabRow.spacing = 4
        tabs.setContentHuggingPriority(.init(750), for: .horizontal)
        tabs.maxChars = 6
        tabs.iconFor = { [weak self] i in self.flatMap { FileIcons.image(for: $0.roots[i].url, isDir: true, open: i == $0.sel) } }
        tabs.onDoubleClick = { [weak self] i in if i == 0 { self?.onChangeRoot?() } }
        tabs.isClosable = { $0 > 0 } // 기본 폴더는 제거 불가
        tabs.onSelect = { [weak self] in self?.selectRoot($0) }
        tabs.onClose = { [weak self] in self?.removeRoot($0) }
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.toolTip = "클릭하면 경로 복사"
        pathLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pathClicked)))

        let col = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.allowsMultipleSelection = true
        outline.onDelete = { [weak self] in self?.trashSelected() }
        outline.onReturn = { [weak self] in self?.renameSelected() }
        outline.onCopyPath = { [weak self] in self?.copySelectedPaths() }
        outline.onOpenSelected = { [weak self] in self?.openSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let refreshBtn = IconButton("arrow.clockwise", "새로고침", self, #selector(refreshClicked), size: 20, point: 10)
        refreshBtn.hoverTint = Theme.accent
        hiddenBtn.hoverTint = Theme.accent
        copyBtn.target = self
        copyBtn.action = #selector(pathClicked)
        pathLabel.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        hiddenBtn.target = self
        hiddenBtn.action = #selector(toggleHidden)
        updateHiddenBtn()
        let pathRow = NSStackView(views: [copyBtn, pathLabel, spacer(), hiddenBtn, refreshBtn])
        pathRow.spacing = 4
        let top = column([tabRow, pathRow], insets: .init(top: 10, left: 10, bottom: 10, right: 10), spacing: 8)
        outline.previewURLs = { [weak self] in self?.selectedURLs ?? [] }
        pin(column([top, hairline(), scroll]))
        widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        reloadTabs()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 다시 읽기. 선택한 파일은 (위치가 바뀌어도) 그대로 선택 유지, 이름 변경 중엔 미룸
    func refresh() {
        if renaming != nil { return }
        let selected = selectedURLs
        roots[sel].refresh()
        outline.reloadData()
        let rows = IndexSet(selected.compactMap { u in
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? FileNode)?.url == u }
        })
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    private let hiddenBtn = IconButton("eye", "숨김 파일 보기/숨기기", nil, #selector(NSText.cut(_:)), size: 20, point: 10)
    private let copyBtn = IconButton("doc.on.doc", "경로 복사", nil, #selector(NSText.copy(_:)), size: 20, point: 10)
    private func updateHiddenBtn() {
        hiddenBtn.image = NSImage(systemSymbolName: FileNode.showHidden ? "eye" : "eye.slash", accessibilityDescription: "숨김 파일")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        hiddenBtn.tint = FileNode.showHidden ? Theme.accent : Theme.fgMuted  // 켜져 있으면 초록
    }
    @objc func toggleHidden() {
        FileNode.showHidden.toggle()
        updateHiddenBtn()
        refresh()
    }

    @objc private func refreshClicked() { refresh() }  // 펼쳐 둔 폴더는 모두 디스크에서 다시 읽음

    // MARK: 폴더 감시 — 현재 폴더 탭(하위 포함)이 바뀌면 바로 다시 읽음 (FSEvents, 0.2초 모아서)
    private var stream: FSEventStreamRef?
    private var watchedPath: String?

    private func watch(_ url: URL) {
        guard watchedPath != url.path else { return }
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        watchedPath = url.path
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated { Unmanaged<Sidebar>.fromOpaque(info).takeUnretainedValue().refresh() }
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    // MARK: 검색 (⌘P)

    var selectedURL: URL? { (outline.item(atRow: outline.selectedRow) as? FileNode)?.url }
    // MARK: 우클릭 메뉴

    private func clickedNode() -> FileNode? { outline.item(atRow: outline.clickedRow) as? FileNode }

    /// 새 파일/폴더를 만들 위치: 클릭한 폴더, 파일이면 그 부모, 빈 곳이면 현재 폴더 탭
    private func targetDir(_ n: FileNode?) -> URL {
        guard let n else { return roots[sel].url }
        return n.isDir ? n.url : n.url.deletingLastPathComponent()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = clickedNode()
        func add(_ title: String, _ sel: Selector) { menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add("새 메모", #selector(menuNewFile))
        add("새 폴더", #selector(menuNewFolder))
        menu.addItem(.separator())
        if n != nil {
            add("이름 변경", #selector(menuRename))
            add("휴지통으로 이동", #selector(menuTrash))
            menu.addItem(.separator())
        }
        add("Finder 에서 보기", #selector(menuReveal))
        menu.addItem(withTitle: "경로 복사", action: #selector(menuCopyPath), keyEquivalent: "c").target = self
        menu.items.last?.keyEquivalentModifierMask = .option
        add("터미널에서 열기", #selector(menuTerminal))
    }

    @objc private func menuNewFile() { create(in: targetDir(clickedNode()), folder: false) }
    @objc private func menuNewFolder() { create(in: targetDir(clickedNode()), folder: true) }
    @objc private func menuRename() { clickedNode().map(beginRename) }
    @objc private func menuTrash() { clickedNode().map { trash([$0.url]) } }
    @objc private func menuReveal() { NSWorkspace.shared.activateFileViewerSelecting([clickedNode()?.url ?? roots[sel].url]) }
    @objc private func menuCopyPath() { copyPaths([clickedNode()?.url ?? roots[sel].url]) }

    /// 선택한 항목들의 절대경로 (여러 개면 줄바꿈). 선택이 없으면 현재 폴더 탭
    func copySelectedPaths() {
        let urls = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
        copyPaths(urls.isEmpty ? [roots[sel].url] : urls)
    }

    private func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(urls.map { $0.path.precomposedStringWithCanonicalMapping }.joined(separator: "\n"), forType: .string)
    }

    var treeView: NSOutlineView { outline }
    @objc private func menuTerminal() { onOpenTerminal?(targetDir(clickedNode())) }

    /// 새 메모(.md) 또는 새 폴더를 만들고 바로 이름 변경 상태로
    func create(in dir: URL, folder: Bool) {
        let base = folder ? "새 폴더" : "새 메모", ext = folder ? "" : ".md"
        var u = dir.appendingPathComponent(base + ext), i = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) \(i)\(ext)"); i += 1 }
        let ok = folder ? (try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)) != nil
                        : FileManager.default.createFile(atPath: u.path, contents: Data())
        guard ok else { NSSound.beep(); return }
        refresh()
        reveal(u)
        if let n = node(for: u) { beginRename(n) }
    }

    // MARK: 이름 변경 (트리 안에서 바로 편집)

    func renameSelected() {
        guard outline.selectedRowIndexes.count == 1, let n = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
        beginRename(n)
    }

    private func beginRename(_ n: FileNode) {
        let row = outline.row(forItem: n)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let tf = cell.textField else { return }
        renaming = n
        tf.isEditable = true
        tf.delegate = self
        window?.makeFirstResponder(tf)
        // 확장자 앞까지만 선택 (Finder 와 같음)
        let name = n.url.lastPathComponent as NSString
        let stem = n.isDir ? name.length : (name.deletingPathExtension as NSString).length
        tf.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, let n = renaming else { return }
        renaming = nil
        tf.isEditable = false
        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        let dest = n.url.deletingLastPathComponent().appendingPathComponent(name)
        if !name.isEmpty, !name.contains("/"), dest != n.url {
            do {
                try FileManager.default.moveItem(at: n.url, to: dest)
                onRenamed?(n.url, dest)
            } catch { NSSound.beep() }
        }
        refresh()
        reveal(dest)
        window?.makeFirstResponder(outline)
    }

    /// 열린 탭 경로 갱신용
    var onRenamed: ((URL, URL) -> Void)?

    func setRoot(_ url: URL) {
        roots[0] = FileNode(url)
        reloadTabs()
    }

    private func reloadTabs() {
        tabs.set(roots.enumerated().map { i, r in
            (i == 0 ? "기본" : r.url.lastPathComponent,
             i == 0 ? "\(r.url.path)\n더블클릭하면 기본 폴더 변경" : r.url.path)
        }, selected: sel)
        pathLabel.stringValue = (roots[sel].url.path as NSString).abbreviatingWithTildeInPath
        watch(roots[sel].url)
        outline.reloadData()
    }

    var rootCount: Int { roots.count }
    var selectedRoot: Int { sel }

    /// 폴더 탭 전환 시 트리에 포커스 → 이어서 ⌘T/⌘W/⌘⇧] 가 탐색기에 적용됨
    func selectRoot(_ i: Int) {
        guard roots.indices.contains(i) else { return }
        sel = i
        roots[i].refresh()
        reloadTabs()
        focus()
    }
    func step(_ d: Int) { selectRoot((sel + d + roots.count) % roots.count) }
    func focus() { window?.makeFirstResponder(outline) }
    func removeCurrent() { if sel > 0 { removeRoot(sel) } else { NSSound.beep() } } // 기본 폴더는 제거 불가

    func addRoot(_ u: URL) {
        if let i = folders.firstIndex(of: u) { selectRoot(i); return }
        roots.append(FileNode(u))
        selectRoot(roots.count - 1)
        onFoldersChanged?()
    }

    private func removeRoot(_ i: Int) {
        guard i > 0 else { return }
        roots.remove(at: i)
        if sel >= i { sel -= 1 }
        reloadTabs()
        onFoldersChanged?()
        focus()
    }

    // MARK: 파일 삭제 / 되돌리기

    func trashSelected() {
        let urls = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        trash(urls)
    }

    /// 휴지통으로 이동 (Finder 와 같음, 휴지통에서도 복구 가능). 되돌리기 = 원래 위치로 이동
    private func trash(_ urls: [URL]) {
        onWillTrash?(urls)
        var moved: [(from: URL, trash: URL)] = []
        for u in urls {
            var res: NSURL?
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: &res)) != nil, let r = res as URL? { moved.append((u, r)) }
        }
        guard !moved.isEmpty else { NSSound.beep(); return }
        outline.fileUndo.registerUndo(withTarget: self) { $0.restore(moved) }
        outline.fileUndo.setActionName("삭제")
        refresh()
    }

    private func restore(_ moved: [(from: URL, trash: URL)]) {
        for m in moved { try? FileManager.default.moveItem(at: m.trash, to: m.from) }
        outline.fileUndo.registerUndo(withTarget: self) { $0.trash(moved.map(\.from)) } // 다시 실행 = 다시 삭제
        outline.fileUndo.setActionName("삭제")
        refresh()
        moved.first.map { reveal($0.from) }
    }

    func undoFileOp() { outline.fileUndo.undo() }

    /// 현재 폴더 탭 아래 경로의 노드 (중간 폴더는 펼침)
    private func node(for url: URL) -> FileNode? {
        let root = roots[sel].url.standardizedFileURL.pathComponents, parts = url.standardizedFileURL.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        var cur = roots[sel]
        for name in parts.dropFirst(root.count) {
            guard let next = cur.children.first(where: { $0.url.lastPathComponent == name }) else { return nil }
            if next.isDir, next !== cur, url.standardizedFileURL != next.url.standardizedFileURL { outline.expandItem(next) }
            cur = next
        }
        return cur
    }

    /// 현재 폴더 탭 안의 파일이면 (하위 폴더 펼쳐서) 선택해서 보여줌. 포커스는 건드리지 않음
    func reveal(_ url: URL) {
        guard let n = node(for: url) else { return }
        let r = outline.row(forItem: n)
        guard r >= 0 else { return }
        outline.selectRowIndexes([r], byExtendingSelection: false)
        outline.scrollRowToVisible(r)
    }

    @objc func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.message = "사이드바에 추가할 폴더를 선택하세요"
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard p.runModal() == .OK else { return }
        p.urls.forEach(addRoot)
    }

    /// 한 번 클릭: 선택만 (폴더는 펼치기/접기). 파일 열기는 더블클릭 또는 ⌘↓
    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? FileNode, n.isDir,
              NSApp.currentEvent?.clickCount ?? 1 == 1 else { return }
        if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }

    @objc private func doubleClicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? FileNode, !n.isDir else { return }
        onOpen?(n.url)
    }

    func openSelected() {
        for r in outline.selectedRowIndexes {
            if let n = outline.item(atRow: r) as? FileNode, !n.isDir { onOpen?(n.url) }
        }
    }

    /// 복사 아이콘 / 경로 라벨 클릭 = 경로 복사 (아이콘이 잠깐 초록 체크로)
    @objc private func pathClicked() {
        copyPaths([roots[sel].url])
        setCopyIcon("checkmark", Theme.accent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.setCopyIcon("doc.on.doc", Theme.fgMuted) }
    }
    private func setCopyIcon(_ symbol: String, _ color: NSColor) {
        copyBtn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "경로 복사")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        copyBtn.tint = color
    }
    var copyIconTint: NSColor { copyBtn.tint }
    func clickPathLabel() { pathClicked() }

    // 폴더 열림/닫힘 아이콘 갱신
    func outlineViewItemDidExpand(_ n: Notification) { (n.userInfo?["NSObject"]).map { outline.reloadItem($0) } }
    func outlineViewItemDidCollapse(_ n: Notification) { (n.userInfo?["NSObject"]).map { outline.reloadItem($0) } }

    // MARK: data source / delegate

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return ((item as? FileNode) ?? roots[sel]).children.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return ((item as? FileNode) ?? roots[sel]).children[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! FileNode).isDir }

    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as! FileNode).url as NSURL
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SoftRowView() }

    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let n = item as! FileNode
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView(), tf = label("", Theme.ui(13), Theme.fg)
            c.imageView = iv
            c.textField = tf
            for v in [iv, tf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = n.url.lastPathComponent
        cell.textField?.isEditable = false
        let hidden = n.url.lastPathComponent.hasPrefix(".")
        cell.textField?.alphaValue = hidden ? 0.55 : 1   // 숨김 파일은 흐리게 (Finder 와 같음)
        cell.imageView?.alphaValue = hidden ? 0.55 : 1
        cell.imageView?.image = FileIcons.image(for: n.url, isDir: n.isDir, open: n.isDir && o.isItemExpanded(n))
        cell.toolTip = n.url.path
        return cell
    }
}

extension FileOutline: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt i: Int) -> QLPreviewItem! { qlItems[i] as NSURL }
    /// 미리보기 창에서 누른 화살표·스페이스는 트리로 (선택 이동 → 미리보기 갱신)
    func previewPanel(_ panel: QLPreviewPanel!, handle e: NSEvent!) -> Bool {
        guard e.type == .keyDown else { return false }
        keyDown(with: e)
        return true
    }
}
