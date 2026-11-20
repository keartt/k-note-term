import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

private let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
let isSelfTest = CommandLine.arguments.contains("--selftest")

struct AppState: Codable {
    var tabs: [String] = []
    var selected = 0
    var extraFolders: [String] = []
    var syntax: [String: String] = [:]   // 사용자가 직접 고른 문법 (경로 → 이름)
    var sidebar = false
    var terminal = false
    var notesDir: String?
    var notesDirChosen: Bool?             // 사용자가 직접 골랐는지 (이전 버전의 자동 지정은 다시 물음)
    var editorFontSize: Double?
    var sidebarWidth: Double?
    var downloadsAdded: Bool?
    var paneTabs: [String]?               // 에디터 분할 시 두 칸의 파일
    var activePane: Int?
    var editorHidden: Bool?
    var splitVertical: Bool?             // 처음 한 번 다운로드 폴더를 탐색기 탭으로 넣었는지

    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KNoteTerm/state.json")
    static func load() -> AppState {
        (try? JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))) ?? AppState()
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }
}

final class Doc {
    enum Media { case pdf, image }

    var url: URL   // 탐색기에서 이름 변경 시 갱신
    let storage: NSTextStorage
    let undo = UndoManager()
    let encoding: String.Encoding
    /// nil = 텍스트 메모, 그 외 = 읽기 전용 뷰어 (편집·저장·빈 파일 삭제 대상 아님)
    let media: Media?
    var syntax: Syntax
    var dirty = false
    var saveError: String?
    var sel = NSRange(location: 0, length: 0)
    var preview = false   // 마크다운 미리보기로 보는 중
    var canPreview: Bool { media == nil && syntax.name == "Markdown" }

    init?(url: URL, syntax: Syntax?) {
        self.url = url
        self.syntax = syntax ?? Syntax.detect(url)
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true, PDFDocument(url: url) != nil {
            media = .pdf; encoding = .utf8; storage = NSTextStorage(); return
        }
        if type?.conforms(to: .image) == true, NSImage(contentsOf: url) != nil {
            media = .image; encoding = .utf8; storage = NSTextStorage(); return
        }
        media = nil
        guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil } // NUL 포함 = 바이너리
        if let s = String(data: data, encoding: .utf8) { encoding = .utf8; storage = NSTextStorage(string: s) }
        else if let s = String(data: data, encoding: cp949) { encoding = cp949; storage = NSTextStorage(string: s) }
        else { return nil }
    }

    func save() {
        guard dirty, media == nil else { return }
        do {
            // 심볼릭 링크(dotfiles 등)는 링크를 파일로 덮지 않도록 실제 대상에 쓴다
            try storage.string.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: encoding)
            dirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// 파일 URL 드롭 시 절대경로를 텍스트로 삽입
final class EditorView: NSTextView {
    var onExternalDrop: (([URL]) -> Void)?
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL] }

    /// 현재 줄 강조 (CotEditor Anura lineHighlight)
    private func drawLineHighlight(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let lm = layoutManager, let tc = textContainer else { return }
        let loc = selectedRange().location
        var line: NSRect
        if loc >= (string as NSString).length, !lm.extraLineFragmentRect.isEmpty {
            line = lm.extraLineFragmentRect
        } else {
            lm.ensureLayout(for: tc)
            let g = lm.glyphIndexForCharacter(at: min(loc, max(0, (string as NSString).length - 1)))
            line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        }
        line.origin.y += textContainerOrigin.y
        line.origin.x = 0
        line.size.width = bounds.width
        Theme.lineHighlight.setFill()
        line.fill()
    }

    /// 첫 줄 오른쪽 위 작은 글씨 (마크다운 작성/수정 일시). 줄 강조 위에 그림
    var dateText: String?
    override func drawBackground(in rect: NSRect) {
        drawLineHighlight(in: rect)
        guard let t = dateText else { return }
        let a: [NSAttributedString.Key: Any] = [.font: Theme.ui(10.5), .foregroundColor: Theme.fgSubtle]
        let size = (t as NSString).size(withAttributes: a)
        // 첫 줄과 같은 높이 (줄 높이 가운데)
        let lineH = layoutManager.map { $0.defaultLineHeight(for: font ?? Theme.mono(14)) * 1.3 } ?? size.height
        (t as NSString).draw(at: NSPoint(x: bounds.width - size.width - 14, y: textContainerOrigin.y + (lineH - size.height) / 2), withAttributes: a)
    }

    /// ⌘⌫: 줄 앞부분 삭제. 이미 줄 맨 앞(지울 게 없음)이면 그 줄 자체를 지움 (앞 줄바꿈 삭제)
    override func deleteToBeginningOfLine(_ sender: Any?) {
        let r = selectedRange(), s = string as NSString
        if r.length == 0, r.location > 0, s.lineRange(for: NSRange(location: r.location, length: 0)).location == r.location {
            deleteBackward(sender)
        } else {
            super.deleteToBeginningOfLine(sender)
        }
    }

    private func urls(_ s: NSDraggingInfo) -> [URL] {
        s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(s)
        return urls(s).isEmpty ? op : .copy
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let list = urls(s)
        guard !list.isEmpty else { return super.performDragOperation(s) }
        // 앱 밖(Finder 등)에서 온 파일은 열기, 탐색기에서 끌어온 건 경로 삽입
        if s.draggingSource == nil, let onExternalDrop { onExternalDrop(list); return true }
        let text = dropText(list, shell: false)
        let at = NSRange(location: characterIndexForInsertion(at: convert(s.draggingLocation, from: nil)), length: 0)
        if shouldChangeText(in: at, replacementString: text) {
            textStorage?.replaceCharacters(in: at, with: text)
            didChangeText()
            setSelectedRange(NSRange(location: at.location + (text as NSString).length, length: 0))
        }
        window?.makeFirstResponder(self)
        return true
    }
}

/// 에디터 왼쪽 줄번호 (줄바꿈된 긴 줄은 첫 줄에만 번호, 현재 줄은 밝게)
final class LineNumberRuler: NSRulerView {
    var fontSize: CGFloat = 14 { didSet { updateWidth() } }
    private var font: NSFont { Theme.mono(max(9, fontSize - 3)) }

    init(_ scroll: NSScrollView, _ tv: NSTextView) {
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = tv
        clipsToBounds = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        updateWidth()
    }
    required init(coder: NSCoder) { fatalError() }

    @objc func redraw() { needsDisplay = true }

    func updateWidth() {
        let n = ((clientView as? NSTextView)?.string.utf16.lazy.filter { $0 == 10 }.count ?? 0) + 1
        let w = ceil(CGFloat(max(3, String(n).count)) * ("0" as NSString).size(withAttributes: [.font: font]).width) + 22
        if ruleThickness != w { ruleThickness = w }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        // macOS 14+ 는 clipsToBounds 기본 false → dirty 가 본문까지 넘어와 글자를 덮었음. 자기 영역만 칠함
        Theme.bg.setFill()
        dirty.intersection(bounds).fill()
        drawHashMarksAndLabels(in: dirty)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let s = tv.string as NSString, f = font
        let caret = s.lineRange(for: NSRange(location: min(tv.selectedRange().location, s.length), length: 0)).location
        func draw(_ n: Int, fragment: NSRect, baseline: CGFloat, current: Bool) {
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: current ? Theme.fg : Theme.fgSubtle]
            let str = "\(n)" as NSString, size = str.size(withAttributes: attrs)
            let y = convert(NSPoint(x: 0, y: fragment.minY + tv.textContainerOrigin.y + baseline), from: tv).y - f.ascender
            str.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y), withAttributes: attrs)
        }
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = s.substring(to: chars.location).utf16.lazy.filter { $0 == 10 }.count + 1
        var i = s.lineRange(for: NSRange(location: chars.location, length: 0)).location
        var lastBaseline: CGFloat?
        while i < s.length, i <= NSMaxRange(chars) {
            let g = lm.glyphIndexForCharacter(at: i)
            lastBaseline = lm.location(forGlyphAt: g).y
            draw(line, fragment: lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil), baseline: lm.location(forGlyphAt: g).y, current: i == caret)
            line += 1
            i = NSMaxRange(s.lineRange(for: NSRange(location: i, length: 0)))
        }
        // 마지막 빈 줄 (파일이 줄바꿈으로 끝나거나 비어 있을 때)
        let extra = lm.extraLineFragmentRect
        if !extra.isEmpty, i >= s.length {
            draw(line, fragment: extra, baseline: lastBaseline ?? extra.height * 0.72, current: caret == s.length)
        }
    }
}

/// 이미지 칸도 클릭/영역 이동으로 포커스를 받을 수 있게 (어느 분할 칸이 활성인지 판단용)
final class FocusableScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with: e) }
}

/// 에디터 분할의 한 칸. 텍스트 / PDF / 이미지 / 마크다운 미리보기 뷰를 겹쳐 두고 문서 종류에 따라 하나만 보임
final class EditorPane: NSView {
    let textView = EditorView(usingTextLayoutManager: false)
    let textScroll = NSScrollView()
    let pdfView = PDFView()
    let imageScroll = FocusableScrollView()
    let imageView = NSImageView()
    let previewView = WKWebView()
    let ring = FocusRing()
    var ruler: LineNumberRuler!
    /// 이 칸에 보이는 문서 (탭 목록 docs 가 소유)
    weak var doc: Doc?

    init() {
        super.init(frame: .zero)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = Theme.bg
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = imageScroll.contentView.bounds
        imageView.autoresizingMask = [.width, .height]
        imageScroll.documentView = imageView
        imageScroll.allowsMagnification = true   // 트랙패드 핀치 확대
        imageScroll.maxMagnification = 8
        imageScroll.backgroundColor = Theme.bg
        imageScroll.automaticallyAdjustsContentInsets = false
        previewView.setValue(false, forKey: "drawsBackground") // 로딩 중 흰 화면 깜빡임 방지
        for v in [textScroll, pdfView, imageScroll, previewView] as [NSView] { v.isHidden = v !== textScroll; pin(v) }
        ring.attach(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    /// 마크다운 메모 첫 줄 오른쪽 위: 작성 / 마지막 수정 일시 (파일 생성일·수정일)
    func updateDates() {
        var t: String?
        if let d = doc, d.media == nil, !d.preview, d.syntax.name == "Markdown",
           let v = try? d.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
           let c = v.creationDate, let m = v.contentModificationDate {
            t = "작성 \(Self.dateFmt.string(from: c))   ·   수정 \(Self.dateFmt.string(from: m))"
        }
        if t != textView.dateText { textView.dateText = t; textView.setNeedsDisplay(textView.visibleRect) }
    }

    /// 이 칸의 텍스트 뷰만 다른 문서로 옮김.
    /// replaceTextStorage 는 같은 문서를 보던 다른 칸까지 통째로 옮겨 버려서(같은 파일 분할 후 한쪽만 바꾸면 둘 다 바뀜) 직접 떼고 붙임
    func attach(_ storage: NSTextStorage) {
        guard let lm = textView.layoutManager, lm.textStorage !== storage else { return }
        lm.textStorage?.removeLayoutManager(lm)
        storage.addLayoutManager(lm)
    }
    var shownText: String { textView.string }

    /// 이 칸에서 키 입력을 받을 뷰
    var focusTarget: NSView {
        if doc?.preview == true { return previewView }
        switch doc?.media {
        case .pdf?: return pdfView
        case .image?: return imageScroll
        case nil: return textView
        }
    }
}

final class MainController: NSObject, NSTextViewDelegate, NSWindowDelegate, WKNavigationDelegate {
    let window = AppWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
    let sidebar: Sidebar
    let terminal = TerminalArea()
    let editorTabs = PillTabBar()
    // 에디터 분할 (⌘\): 탭 바는 하나, 칸(최대 2)마다 탭 하나씩 보여줌. 탭 클릭 = 활성 칸에 표시
    private var panes: [EditorPane] = []
    private var active = 0
    private let editorSplit = ThinSplit()
    private var pane: EditorPane { panes[active] }
    var isSplit: Bool { panes.count == 2 }
    private var textView: EditorView { pane.textView }
    private var textScroll: NSScrollView { pane.textScroll }
    private var pdfView: PDFView { pane.pdfView }
    private var imageScroll: NSScrollView { pane.imageScroll }
    private var imageView: NSImageView { pane.imageView }
    private var previewView: WKWebView { pane.previewView }
    private var rulers: [LineNumberRuler] { panes.map(\.ruler) }
    private var editing: EditorView { textView }
    var editorText: EditorView { textView }
    var lineRulerWidth: CGFloat { rulers.first?.ruleThickness ?? 0 }
    var paneDocNames: [String] { panes.map { $0.doc?.url.lastPathComponent ?? "-" } }
    var paneTexts: [String] { panes.map(\.shownText) }
    var dateText: String? { pane.textView.dateText }
    var activePane: Int { active }
    /// 재실행 시 복원할 분할 상태 (창이 뜬 뒤 restoreLayout 에서 적용)
    private var pendingSplit: (paths: [String], active: Int, vertical: Bool)?
    private let syntaxPopup = NSPopUpButton()
    private let zoomLabel = NSButton(title: "100%", target: nil, action: nil)
    private var zoomBox: NSStackView!
    private let emptyView = NSView()
    private let previewBtn = IconButton("eye", "마크다운 미리보기 (⌘⇧P)", nil, #selector(togglePreview))
    let newBtn = IconButton("plus", "새 메모 (⌘T)", nil, #selector(newNote))
    private let statusLeft = label("", Theme.ui(11.5)), statusRight = label("", Theme.ui(11.5))
    private let mainSplit = ThinSplit(), rightSplit = ThinSplit()
    private var editorPane: NSView!
    private var headerRight: NSView!
    /// 에디터를 숨기면 같이 숨기는 상단 항목 (메모 탭, +, 미리보기, 분할, 문법)
    private var editorOnlyHeader: [NSView] = []
    private(set) var docs: [Doc] = []
    /// 활성 칸에 보이는 탭 번호 (-1 = 없음)
    private var cur: Int { pane.doc.flatMap { d in docs.firstIndex { $0 === d } } ?? -1 }
    private var state = AppState.load()
    private var notesDir: URL
    private var saveTimer: Timer?, hlTimer: Timer?
    private var tabsLeading: NSLayoutConstraint!
    private let maxSidebarFraction: CGFloat = 0.30
    private let minTabsX: CGFloat = 116          // 신호등 + 사이드바 버튼 오른쪽
    private var applyingSidebar = false
    private let rings = (sidebar: FocusRing(), editor: FocusRing(), terminal: FocusRing())

    private var doc: Doc? { docs.indices.contains(cur) ? docs[cur] : nil }
    private var editorSize: CGFloat { CGFloat(state.editorFontSize ?? 14) }
    private var baseAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        return [.font: Theme.mono(editorSize), .foregroundColor: Theme.fg, .paragraphStyle: p]
    }
    var terminalFocused: Bool { (window.firstResponder as? NSView)?.isDescendant(of: terminal) ?? false }
    var sidebarVisible: Bool { sidebar.superview != nil }
    var sidebarFocused: Bool { (window.firstResponder as? NSView)?.isDescendant(of: sidebar) ?? false }
    var terminalVisible: Bool { terminal.superview != nil }
    var editorHeight: CGFloat { rightSplit.arrangedSubviews.first?.frame.height ?? 0 }
    var splitHeight: CGFloat { rightSplit.bounds.height }
    var sidebarWidth: CGFloat { sidebar.frame.width }
    var currentURL: URL? { doc?.url }
    var currentViewer: String {
        !emptyView.isHidden ? "empty" : !pdfView.isHidden ? "pdf" : !imageScroll.isHidden ? "image" : !previewView.isHidden ? "preview" : !emptyView.isHidden ? "empty" : "text"
    }
    var visibleRing: String {
        [("sidebar", rings.sidebar), ("editor", rings.editor), ("terminal", rings.terminal)]
            .filter { $0.1.isFocused }.map(\.0).joined(separator: ",")
    }
    var tabsX: CGFloat { editorTabs.convert(NSPoint.zero, to: nil).x }
    func debugSetSyntax(_ name: String) { syntaxPopup.selectItem(withTitle: name); syntaxChanged() }
    func debugSetSidebarWidth(_ w: CGFloat) { mainSplit.setPosition(w, ofDividerAt: 0) }
    func debugRelayout() { updateStatus(); reloadTabs(); sidebar.refresh(); window.contentView?.layoutSubtreeIfNeeded() }

    override init() {
        let fm = FileManager.default
        if let p = state.notesDir, state.notesDirChosen == true, fm.fileExists(atPath: p) {
            notesDir = URL(fileURLWithPath: p)
        } else if isSelfTest {
            notesDir = URL(fileURLWithPath: state.notesDir ?? NSTemporaryDirectory())
        } else {
            // 최초 실행: 폴더를 고르고 쓰기 권한이 확인돼야 시작 (취소 시 다시 묻거나 종료)
            notesDir = MainController.chooseNotesDirUntilValid(current: state.notesDir)
            state.notesDir = notesDir.path
            state.notesDirChosen = true
            state.save()
        }
        // 처음 한 번: 다운로드 폴더를 탐색기 추가 탭으로 (닫으면 다시 안 생김)
        if state.downloadsAdded != true, !isSelfTest {
            let dl = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
            if !state.extraFolders.contains(dl) { state.extraFolders.insert(dl, at: 0) }
            state.downloadsAdded = true
            state.save()
        }
        sidebar = Sidebar(folders: [notesDir] + state.extraFolders.map { URL(fileURLWithPath: $0) })
        super.init()
        buildUI()
        sidebar.onOpen = { [weak self] in self?.open($0) }
        sidebar.onWillTrash = { [weak self] urls in self?.closeTabs(under: urls) }
        sidebar.onRenamed = { [weak self] in self?.renamed($0, $1) }
        sidebar.onChangeRoot = { [weak self] in self?.changeNotesDir() }
        sidebar.onOpenTerminal = { [weak self] in self?.setTerminal(true, newTabAt: $0.path) }
        editorTabs.menuFor = { [weak self] in self?.tabMenu($0) }
        // 탭 더블클릭 = 파일 이름 변경 (확장자는 그대로, 이름 부분만 편집)
        editorTabs.editText = { [weak self] i in self?.docs[safe: i]?.url.deletingPathExtension().lastPathComponent ?? "" }
        editorTabs.onRename = { [weak self] i, name in self?.renameDoc(i, to: name) }
        sidebar.onFoldersChanged = { [weak self] in
            guard let self else { return }
            state.extraFolders = sidebar.folders.dropFirst().map(\.path)
            state.save()
        }
        terminal.onEmpty = { [weak self] in self?.setTerminal(false) }
        window.onResponderChange = { [weak self] r in
            guard let self else { return }
            terminal.noteFocus(r)
            // 다른 분할 칸을 클릭/포커스하면 그 칸이 활성 (탭 표시·상태바가 따라감)
            if let v = r as? NSView, let i = panes.firstIndex(where: { v.isDescendant(of: $0) }), i != active {
                active = i
                refreshActive()
            }
            updateFocusRing()
        }
        window.onMouseDown = { [weak self] in self?.focusArea(clicked: $0) }
        window.onCtrlTab = { [weak self] in $0 > 0 ? self?.nextTab() : self?.prevTab() } // ⌘⇧] / ⌘⇧[ 와 같은 라우팅
        if let pt = state.paneTabs, pt.count == 2 {
            pendingSplit = (pt, state.activePane ?? 0, state.splitVertical ?? true)
        }

        for p in state.tabs where fm.fileExists(atPath: p) { open(URL(fileURLWithPath: p), select: false) }
        if docs.isEmpty { showEmpty() } else { select(min(max(state.selected, 0), docs.count - 1)) }
    }

    private static func askNotesDir(first: Bool, current: String?) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "이 폴더 사용"
        p.message = first ? "KNoteTerm 시작: 메모가 자동저장될 기본 폴더를 선택하세요" : "새 기본 폴더를 선택하세요"
        p.directoryURL = current.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return p.runModal() == .OK ? p.url : nil
    }

    /// 실제로 파일을 써 보고 지워서 권한 확인 (문서 폴더 등은 여기서 macOS 권한 창이 뜸)
    private static func canWrite(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".knoteterm-write-test")
        guard (try? Data().write(to: probe)) != nil else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    private static func alert(_ title: String, _ info: String, _ buttons: [String]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        buttons.forEach { a.addButton(withTitle: $0) }
        return a.runModal()
    }

    private static func chooseNotesDirUntilValid(current: String?) -> URL {
        while true {
            guard let u = askNotesDir(first: true, current: current) else {
                if alert("기본 폴더가 필요합니다", "메모를 자동저장할 폴더를 정해야 시작할 수 있습니다.", ["다시 선택", "종료"]) != .alertFirstButtonReturn { exit(0) }
                continue
            }
            if canWrite(u) { return u }
            _ = alert("이 폴더에 쓸 수 없습니다", "\(u.path)\n\n권한을 허용하지 않았거나 쓰기 금지된 폴더입니다. 시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더 에서 KNoteTerm 을 허용하거나 다른 폴더를 고르세요.", ["다시 선택"])
        }
    }

    /// 창이 화면에 뜬 뒤 (분할 크기 계산이 가능할 때) 사이드바/터미널 상태 복원
    func restoreLayout() {
        window.contentView?.layoutSubtreeIfNeeded()
        if state.sidebar { setSidebar(true) }
        if state.terminal { setTerminal(true) }
        if state.editorHidden == true { setEditor(false) }
        if let ps = pendingSplit {
            pendingSplit = nil
            let idx = ps.paths.map { p in docs.firstIndex { $0.url.path == p } }
            if let a = idx[0], let b = idx[1] {
                active = 0
                select(a)
                splitEditor(vertical: ps.vertical)
                select(b)
                if ps.active == 0 { window.makeFirstResponder(panes[0].focusTarget) }
            }
        }
    }

    func persist() {
        docs.forEach { $0.save() }
        // 집중 모드 중 종료해도 다음 실행은 켜기 전 레이아웃으로
        if let f = focusMode { state.sidebar = f.sidebar; state.editorHidden = !f.editor }
        state.tabs = docs.map(\.url.path)
        state.selected = cur
        if pendingSplit == nil {
            state.paneTabs = isSplit ? panes.map { $0.doc?.url.path ?? "" } : nil
            state.activePane = active
            state.splitVertical = editorSplit.isVertical
        }
        state.save()
    }

    // MARK: UI

    private func buildUI() {
        window.delegate = self // 윈도우 delegate 여야 메뉴 단축키(nil-target 액션)가 이 객체까지 도달함
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = Theme.bg
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 460)
        window.center()
        window.setFrameAutosaveName("main")

        // 에디터 칸 (분할하면 하나 더)
        panes = [makePane()]
        editorSplit.isVertical = true
        editorSplit.addSubview(panes[0])
        // 모든 탭을 닫으면: 가운데 + 버튼만
        newBtn.target = self
        previewBtn.target = self
        let bigPlus = IconButton("plus", "새 메모 (⌘T)", self, #selector(newNote), size: 56, point: 22)
        bigPlus.style(bg: Theme.surface, border: Theme.border, radius: 14)
        let hint = label("새 메모", Theme.ui(12), Theme.fgSubtle)
        let emptyCol = NSStackView(views: [bigPlus, hint])
        emptyCol.orientation = .vertical
        emptyCol.spacing = 10
        emptyCol.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(emptyCol)
        emptyCol.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor).isActive = true
        emptyCol.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor).isActive = true
        emptyView.isHidden = true
        let body = NSView()
        for v in [editorSplit, emptyView] as [NSView] { body.pin(v) }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        body.setContentCompressionResistancePriority(.init(1), for: .vertical)

        // PDF·이미지 확대 축소: [−] 100% [+]  (배율 클릭 = 화면에 맞춤)
        zoomLabel.isBordered = false
        zoomLabel.font = Theme.ui(11.5, 6)
        zoomLabel.contentTintColor = Theme.fg
        zoomLabel.target = self
        zoomLabel.action = #selector(zoomFit)
        zoomLabel.toolTip = "클릭하면 화면에 맞춤 (⌘0)"
        _ = fixed(zoomLabel, w: 48)
        zoomBox = NSStackView(views: [IconButton("minus", "축소 (⌘-)", self, #selector(zoomOut), size: 20, point: 10), zoomLabel,
                                      IconButton("plus", "확대 (⌘+)", self, #selector(zoomIn), size: 20, point: 10)])
        zoomBox.spacing = 0
        zoomBox.isHidden = true
        let status = NSStackView(views: [statusLeft, spacer(), zoomBox, statusRight])
        status.setCustomSpacing(14, after: zoomBox)
        status.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        _ = fixed(status, h: 28)

        editorPane = column([body, hairline(), status])

        // 헤더: [신호등 자리][사이드바][에디터 탭들][문법 선택][터미널]
        // ⌥클릭 = 다른 쪽 칸에 열기 (분할 안 돼 있으면 분할)
        editorTabs.onSelect = { [weak self] i in
            if NSEvent.modifierFlags.contains(.option) { self?.openInOther(i) } else { self?.select(i) }
        }
        editorTabs.onClose = { [weak self] in self?.close($0) }
        syntaxPopup.addItems(withTitles: Syntax.all.map(\.name))
        syntaxPopup.isBordered = false
        syntaxPopup.font = Theme.ui(12, 6)
        syntaxPopup.contentTintColor = Theme.fg
        syntaxPopup.target = self
        syntaxPopup.action = #selector(syntaxChanged)
        let syntaxBox = NSView()
        syntaxBox.style(bg: Theme.surface, border: Theme.border, radius: Theme.rControl)
        syntaxBox.pin(syntaxPopup, insets: .init(top: 2, left: 6, bottom: 2, right: 4))
        syntaxBox.setContentHuggingPriority(.required, for: .horizontal)
        syntaxBox.toolTip = "텍스트 유형 (하이라이트)"

        // 메모 탭은 에디터 왼쪽 끝(사이드바 오른쪽)에 맞춰 시작 → alignTabs()
        let header = HeaderView()
        let sidebarBtn = IconButton("sidebar.left", "사이드바 (⌘B)", self, #selector(toggleSidebar))
        let splitBtn = IconButton("rectangle.split.2x1", "에디터 분할 (⌘\\)", self, #selector(toggleEditorSplit))
        let right = NSStackView(views: [previewBtn, splitBtn, syntaxBox,
                                        IconButton("doc.text", "에디터 (⌘⇧E)", self, #selector(toggleEditor)),
                                        IconButton("terminal", "터미널 (⌘⇧T)", self, #selector(toggleTerminal))])
        editorOnlyHeader = [editorTabs, newBtn, previewBtn, splitBtn, syntaxBox]
        right.spacing = 4
        right.setCustomSpacing(8, after: syntaxBox)
        headerRight = right
        editorTabs.setContentHuggingPriority(.init(750), for: .horizontal) // 탭 너비만큼, 넘치면 줄어듦
        for v in [sidebarBtn, editorTabs, newBtn, right] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }
        tabsLeading = editorTabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: minTabsX)
        NSLayoutConstraint.activate([
            sidebarBtn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 78),
            right.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            // "이하" 만 걸면 너비가 정해지지 않아 가끔 0 이 되어 탭이 사라졌음 → 오른쪽 버튼까지 꽉 채움
            editorTabs.trailingAnchor.constraint(equalTo: newBtn.leadingAnchor, constant: -4),
            newBtn.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            newBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabsLeading,
            sidebarBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            editorTabs.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            right.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        let titlebarH = window.frame.height - window.contentLayoutRect.height
        _ = fixed(header, h: max(40, titlebarH))

        // 상단: [탐색기 | 에디터] (mainSplit), 하단: 터미널 → 전체를 rightSplit 이 위/아래로 나눔
        rightSplit.isVertical = false
        mainSplit.addSubview(editorPane)
        rightSplit.addSubview(mainSplit)
        rings.sidebar.attach(to: sidebar)
        rings.editor.attach(to: editorPane)
        rings.terminal.attach(to: terminal)
        mainSplit.isVertical = true
        mainSplit.maxFirstFraction = maxSidebarFraction
        mainSplit.onResize = { [weak self] in
            guard let self else { return }
            // 창을 줄여도 탐색기는 30% 를 넘지 않음
            let limit = (mainSplit.bounds.width * maxSidebarFraction).rounded(.down)
            if sidebarVisible, !applyingSidebar, mainSplit.bounds.width > 0, sidebar.frame.width > limit + 1 {
                mainSplit.setPosition(limit, ofDividerAt: 0); return
            }
            if sidebarVisible, sidebar.frame.width > 0, !applyingSidebar { state.sidebarWidth = Double(sidebar.frame.width) }
            alignTabs()
        }

        // 스택뷰 대신 직접 제약: 분할 뷰가 남은 영역을 꽉 채우도록
        let content = DropView(), line = hairline()
        content.onDrop = { [weak self] in self?.importExternal($0) }
        for v in [header, line, rightSplit] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        chrome = [header, line]
        chromeTop = rightSplit.topAnchor.constraint(equalTo: line.bottomAnchor)
        bareTop = rightSplit.topAnchor.constraint(equalTo: content.topAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
            chromeTop,
            rightSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ] + [header, line, rightSplit].flatMap { [
            $0.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            $0.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ] })
        window.contentView = content
    }

    private func makePane() -> EditorPane {
        let p = EditorPane()
        p.ruler = setupEditor(p.textView, p.textScroll)
        p.textView.onExternalDrop = { [weak self] in self?.importExternal($0) }
        p.previewView.navigationDelegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(updateZoomLabel), name: .PDFViewScaleChanged, object: p.pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateZoomLabel), name: NSScrollView.didEndLiveMagnifyNotification, object: p.imageScroll)
        return p
    }

    private func setupEditor(_ tv: EditorView, _ sc: NSScrollView) -> LineNumberRuler {
        tv.delegate = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.backgroundColor = Theme.bg
        tv.insertionPointColor = Theme.accent
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.textContainerInset = NSSize(width: 20, height: 16)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = .width
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        sc.hasVerticalScroller = true
        sc.drawsBackground = false
        sc.automaticallyAdjustsContentInsets = false
        sc.documentView = tv
        tv.textContainerInset = NSSize(width: 10, height: 16)
        let ruler = LineNumberRuler(sc, tv)
        ruler.fontSize = editorSize
        sc.verticalRulerView = ruler
        sc.hasVerticalRuler = true
        sc.rulersVisible = true
        return ruler
    }

    /// 분할 중이면 화면에 떠 있는 탭에 ◧(왼쪽/위) ◨(오른쪽/아래) 표시
    var tabTitles: [String] {
        docs.map { d in
            var t = d.url.lastPathComponent
            if isSplit {
                if panes[0].doc === d { t += "  ◧" }
                if panes[1].doc === d { t += "  ◨" }
            }
            return t
        }
    }

    private func reloadTabs() {
        let other = isSplit ? panes[1 - active].doc.flatMap { o in docs.firstIndex { $0 === o } } : nil
        editorTabs.set(zip(tabTitles, docs).map { ($0, $1.url.path) }, selected: cur, secondary: other)
    }

    private func updateStatus() {
        panes.forEach { $0.updateDates() }   // 저장되면 수정 시각도 갱신
        zoomBox.isHidden = doc?.media == nil
        updateZoomLabel()
        guard let d = doc else { statusLeft.stringValue = ""; statusRight.stringValue = ""; return }
        if d.preview {
            statusLeft.textColor = Theme.fgMuted
            statusLeft.stringValue = "미리보기   ·   ⌘⇧P 또는 눈 아이콘으로 편집"
            statusRight.stringValue = "Markdown   ·   읽기 전용 보기"
            return
        }
        if let m = d.media {
            statusLeft.textColor = Theme.fgMuted
            switch m {
            case .pdf: statusLeft.stringValue = "PDF   ·   \(pdfView.document?.pageCount ?? 0)쪽"
            case .image:
                let rep = imageView.image?.representations.first
                statusLeft.stringValue = "이미지   ·   \(rep?.pixelsWide ?? 0) × \(rep?.pixelsHigh ?? 0) px   ·   핀치로 확대"
            }
            statusRight.stringValue = "읽기 전용   ·   \(d.url.pathExtension.uppercased())"
            return
        }
        // 편집 도중(다른 뷰 선택 보정 알림 등)엔 선택 범위가 잠깐 문자열보다 클 수 있음 → 잘라서 사용
        let tv = editing, s = tv.string as NSString, sr = tv.selectedRange()
        let r = NSRange(location: min(sr.location, s.length), length: min(sr.length, s.length - min(sr.location, s.length)))
        let line = s.substring(to: r.location).utf16.lazy.filter { $0 == 10 }.count + 1
        let col = r.location - s.lineRange(for: NSRange(location: r.location, length: 0)).location + 1
        let lines = tv.string.utf16.lazy.filter { $0 == 10 }.count + 1
        var left = "줄 \(line), 열 \(col)   ·   \(lines)줄   ·   \(tv.string.count)자"
        if r.length > 0 { left += "   ·   선택 \(s.substring(with: r).count)자" }
        if let e = d.saveError { left += "   ·   ⚠︎ 저장 실패: \(e)" }
        statusLeft.stringValue = left
        statusLeft.textColor = d.saveError == nil ? Theme.fgMuted : .systemRed
        statusRight.stringValue = "\(d.syntax.name)   ·   \(String.localizedName(of: d.encoding))   ·   \(d.dirty ? "저장 중…" : "저장됨")"
    }

    // MARK: 메모 탭

    /// 기본은 항상 편집기. preview 는 미리보기 안의 링크로 연 문서만 (미리보기 상태는 저장하지 않음)
    func open(_ url: URL, select sel: Bool = true, preview: Bool = false) {
        if let i = docs.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            if sel { select(i) }
            return
        }
        // 텍스트·PDF·이미지가 아니면 (pptx 등) Finder 처럼 기본 앱으로
        guard let d = Doc(url: url, syntax: Syntax.named(state.syntax[url.path])) else {
            if sel, !isSelfTest { NSWorkspace.shared.open(url) }
            return
        }
        d.preview = preview && d.canPreview
        docs.append(d)
        if sel { select(docs.count - 1) }
    }

    /// 탭 클릭 = 활성 칸에 표시
    private func select(_ i: Int) {
        guard docs.indices.contains(i) else { return }
        setEditor(true)  // 숨겨 둔 상태에서 파일을 열면 다시 보임
        emptyView.isHidden = true
        editorSplit.isHidden = false
        show(docs[i], in: pane)
        refreshActive()
        if !terminalFocused { window.makeFirstResponder(editorFocusTarget) }
    }

    /// 칸 하나에 문서 표시 (텍스트·PDF·이미지·미리보기 중 하나만 보임)
    private func show(_ d: Doc, in p: EditorPane) {
        if let old = p.doc, old.media == nil, !old.preview { old.sel = p.textView.selectedRange() }
        p.doc = d
        if !d.canPreview { d.preview = false }
        p.textScroll.isHidden = d.media != nil || d.preview
        p.pdfView.isHidden = d.media != .pdf
        p.imageScroll.isHidden = d.media != .image
        p.previewView.isHidden = !d.preview
        if d.preview { renderPreview(d, in: p) }
        switch d.media {
        case .pdf?:
            if p.pdfView.document?.documentURL != d.url { p.pdfView.document = PDFDocument(url: d.url) }
        case .image?:
            p.imageView.image = NSImage(contentsOf: d.url)
            p.imageScroll.magnification = 1
        case nil:
            p.attach(d.storage)
            p.textView.typingAttributes = baseAttrs
            p.ruler.updateWidth()
            d.syntax.apply(to: d.storage, base: baseAttrs)
            let r = NSRange(location: min(d.sel.location, d.storage.length), length: 0)
            p.textView.setSelectedRange(r)
            p.textView.scrollRangeToVisible(r)
        }
    }

    /// 활성 칸 기준으로 헤더(문법·미리보기)·제목·탭·상태바 갱신
    private func refreshActive() {
        guard let d = doc else { reloadTabs(); updateStatus(); return }
        syntaxPopup.isEnabled = d.media == nil
        if d.media == nil { syntaxPopup.selectItem(withTitle: d.syntax.name) }
        previewBtn.isHidden = !d.canPreview
        previewBtn.contentTintColor = d.preview ? Theme.accent : Theme.fgMuted
        window.title = d.url.lastPathComponent
        window.representedURL = d.url
        if sidebarVisible { sidebar.reveal(d.url) } // 탐색기에서 현재 파일 표시
        reloadTabs()
        updateStatus()
        updateFocusRing()
        persist()
    }

    // MARK: 에디터 분할

    @objc func toggleEditorSplit() { isSplit ? mergeSplit() : splitEditor(vertical: true) } // 분할은 항상 좌우로 시작

    /// 분할: 새 칸에 지금 파일을 그대로 (같은 파일 두 화면). 이후 탭 클릭은 활성 칸으로
    private func splitEditor(vertical: Bool) {
        guard let d = doc, !isSplit else { NSSound.beep(); return }
        let p = makePane()
        editorSplit.isVertical = vertical
        panes.append(p)
        editorSplit.addSubview(p)
        editorSplit.adjustSubviews()
        editorSplit.setPosition((vertical ? editorSplit.bounds.width : editorSplit.bounds.height) / 2, ofDividerAt: 0)
        show(d, in: p)
        active = 1
        refreshActive()
        window.makeFirstResponder(p.focusTarget)
    }

    /// 분할 닫기: 활성 칸만 남김
    private func mergeSplit() {
        guard isSplit else { return }
        dropOtherPane()
        refreshActive()
        if !terminalFocused, !sidebarFocused { window.makeFirstResponder(editorFocusTarget) }
    }

    private func dropOtherPane() {
        guard isSplit else { return }
        let drop = panes[1 - active]
        if let d = drop.doc, d.media == nil, !d.preview, drop.textView.window != nil, d !== pane.doc { d.sel = drop.textView.selectedRange() }
        drop.attach(NSTextStorage()) // 안 보이는 뷰가 계속 레이아웃하지 않도록
        drop.removeFromSuperview()
        panes = [pane]
        active = 0
    }

    /// 분할 방향 전환 (좌우 ↔ 위아래)
    @objc func rotateEditorSplit() {
        guard isSplit else { NSSound.beep(); return }
        editorSplit.isVertical.toggle()
        editorSplit.adjustSubviews()
        editorSplit.setPosition((editorSplit.isVertical ? editorSplit.bounds.width : editorSplit.bounds.height) / 2, ofDividerAt: 0)
        persist()
    }

    /// 탭을 다른 쪽 칸에 표시 (분할 안 돼 있으면 분할부터)
    func openInOther(_ i: Int) {
        guard docs.indices.contains(i) else { return }
        if isSplit { active = 1 - active } else { splitEditor(vertical: true) }
        select(i)
    }

    /// 앱 밖에서 가져온 파일/폴더: 폴더는 탐색기 새 탭, 파일은 그 폴더를 탭으로 추가하고 메모 탭에서 열기
    func importExternal(_ urls: [URL]) {
        setSidebar(true)
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { sidebar.addRoot(u); continue }
            sidebar.addRoot(u.deletingLastPathComponent())
            sidebar.reveal(u)
            open(u)
        }
    }

    /// 탐색기에서 이름이 바뀐 파일/폴더 → 열린 탭 경로 갱신
    private func renamed(_ old: URL, _ new: URL) {
        let o = old.standardizedFileURL.path
        for d in docs {
            let p = d.url.standardizedFileURL.path
            if p == o { d.url = new }
            else if p.hasPrefix(o + "/") { d.url = URL(fileURLWithPath: new.path + p.dropFirst(o.count)) }
        }
        reloadTabs()
        doc.map { window.title = $0.url.lastPathComponent; window.representedURL = $0.url }
        persist()
    }

    /// 메모 탭 이름 변경 = 실제 파일 이름 변경 (확장자 유지)
    /// 확장자만 바꿈 (같은 이름 파일이 있으면 그대로 둠)
    private func changeExtension(_ i: Int, to ext: String) {
        guard let d = docs[safe: i] else { return }
        let dest = d.url.deletingPathExtension().appendingPathExtension(ext)
        guard dest != d.url, !FileManager.default.fileExists(atPath: dest.path) else { return }
        d.save()
        let old = d.url
        guard (try? FileManager.default.moveItem(at: old, to: dest)) != nil else { NSSound.beep(); return }
        if let s = state.syntax.removeValue(forKey: old.path) { state.syntax[dest.path] = s }
        renamed(old, dest)
        sidebar.refresh()
        if sidebarVisible { sidebar.reveal(dest) }
    }

    func renameDoc(_ i: Int, to stem: String) {
        guard let d = docs[safe: i] else { return }
        let ext = d.url.pathExtension
        let dest = d.url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? stem : stem + "." + ext)
        defer { window.makeFirstResponder(editorFocusTarget) }
        guard !stem.isEmpty, !stem.contains("/"), !stem.hasPrefix("."), dest != d.url else { reloadTabs(); return }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            _ = MainController.alert("같은 이름의 파일이 이미 있습니다", dest.lastPathComponent, ["확인"])
            reloadTabs()
            return
        }
        d.save()
        let old = d.url
        do { try FileManager.default.moveItem(at: old, to: dest) } catch {
            _ = MainController.alert("이름을 바꿀 수 없습니다", error.localizedDescription, ["확인"])
            reloadTabs()
            return
        }
        if let s = state.syntax.removeValue(forKey: old.path) { state.syntax[dest.path] = s }
        renamed(old, dest)
        sidebar.refresh()
        if sidebarVisible { sidebar.reveal(dest) }
    }

    // MARK: 메모 탭 우클릭 메뉴

    private func tabMenu(_ i: Int) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("이름 변경") { [weak self] in
            guard let self, docs.indices.contains(i) else { return }
            if i != cur { select(i) }
            editorTabs.beginEdit(i)
        })
        m.addItem(ClosureMenuItem(isSplit ? "다른 쪽 칸에 열기 (⌥클릭)" : "오른쪽에 분할해서 열기 (⌥클릭)") { [weak self] in self?.openInOther(i) })
        m.addItem(.separator())
        for (t, s) in [("닫기", #selector(menuCloseTab(_:))), ("다른 탭 모두 닫기", #selector(menuCloseOthers(_:))),
                       ("", nil), ("경로 복사", #selector(menuCopyTabPath(_:))), ("Finder 에서 보기", #selector(menuTabFinder(_:))),
                       ("탐색기에서 보기", #selector(menuTabSidebar(_:)))] as [(String, Selector?)] {
            guard let s else { m.addItem(.separator()); continue }
            let it = m.addItem(withTitle: t, action: s, keyEquivalent: "")
            it.target = self
            it.tag = i
        }
        return m
    }
    @objc private func menuCloseTab(_ s: NSMenuItem) { if docs.indices.contains(s.tag) { close(s.tag) } }
    @objc private func menuCloseOthers(_ s: NSMenuItem) {
        guard docs.indices.contains(s.tag) else { return }
        let keep = docs[s.tag]
        for i in docs.indices.reversed() where docs[i] !== keep { close(i) }
    }
    @objc private func menuCopyTabPath(_ s: NSMenuItem) {
        guard docs.indices.contains(s.tag) else { return }
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(docs[s.tag].url.path.precomposedStringWithCanonicalMapping, forType: .string)
    }
    @objc private func menuTabFinder(_ s: NSMenuItem) {
        if docs.indices.contains(s.tag) { NSWorkspace.shared.activateFileViewerSelecting([docs[s.tag].url]) }
    }
    @objc private func menuTabSidebar(_ s: NSMenuItem) {
        guard docs.indices.contains(s.tag) else { return }
        importExternal([docs[s.tag].url]) // 폴더 탭이 없으면 추가하고 선택
    }

    /// 휴지통으로 가는 파일(또는 그 폴더 안 파일)의 탭을 닫음
    private func closeTabs(under urls: [URL]) {
        let paths = urls.map(\.standardizedFileURL.path)
        for i in docs.indices.reversed() {
            let p = docs[i].url.standardizedFileURL.path
            if paths.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { close(i, deleteEmpty: false) }
        }
    }

    private func close(_ i: Int, deleteEmpty: Bool = true) {
        let d = docs[i]
        d.save()
        // 기본 폴더의 빈 메모는 흔적 남기지 않고 삭제
        if deleteEmpty, d.media == nil, d.storage.length == 0, d.url.deletingLastPathComponent().standardizedFileURL == notesDir.standardizedFileURL {
            try? FileManager.default.removeItem(at: d.url)
        }
        let wasCurrent = pane.doc === d
        docs.remove(at: i)
        if docs.isEmpty { showEmpty(); sidebar.refresh(); return }
        // 이 탭을 보여주던 칸은 옆 탭으로
        let next = docs[min(i, docs.count - 1)]
        for p in panes where p.doc === d { show(next, in: p) }
        refreshActive()
        if wasCurrent, !terminalFocused, !sidebarFocused { window.makeFirstResponder(editorFocusTarget) }
        sidebar.refresh()
    }

    /// 탭이 하나도 없을 때: 가운데 + 버튼만 (누르거나 ⌘T 로 새 메모)
    private func showEmpty() {
        dropOtherPane()
        pane.doc = nil
        pane.attach(NSTextStorage())
        editorSplit.isHidden = true
        emptyView.isHidden = false
        previewBtn.isHidden = true
        syntaxPopup.isEnabled = false
        window.title = "KNoteTerm"
        window.representedURL = nil
        reloadTabs()
        updateStatus()
        if !terminalFocused, !sidebarFocused { window.makeFirstResponder(nil) }
        updateFocusRing()
        persist()
    }

    // MARK: 마크다운 미리보기

    @objc func togglePreview() {
        guard let d = doc, d.canPreview else { NSSound.beep(); return }
        if !d.preview { d.sel = editing.selectedRange(); d.save() }
        d.preview.toggle()
        for p in panes where p.doc === d { show(d, in: p) }
        refreshActive()
        window.makeFirstResponder(editorFocusTarget)
    }

    /// WebKit 은 파일로 띄워야 문서 옆 상대경로 이미지까지 읽을 수 있음
    private func renderPreview(_ d: Doc, in p: EditorPane) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("knoteterm-preview-\(ObjectIdentifier(p).hashValue).html")
        try? Markdown.page(d.storage.string, base: d.url.deletingLastPathComponent()).write(to: out, atomically: true, encoding: .utf8)
        p.previewView.loadFileURL(out, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    /// 미리보기 안 링크: 웹 링크는 브라우저, 로컬 파일은 앱 탭으로
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard a.navigationType == .linkActivated, let u = a.request.url else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if u.isFileURL { open(u, preview: true) } else { NSWorkspace.shared.open(u) }
    }

    var previewText: String { docs[safe: cur]?.preview == true ? Markdown.html(docs[cur].storage.string) : "" }

    func closeTabAt(_ i: Int) { if docs.indices.contains(i) { close(i) } }
    @objc func closeCurrent() { if cur >= 0 { close(cur) } }

    /// 기본 폴더에 메모1, 메모2 … (기존 최대 번호 + 1)
    @objc func newNote() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: notesDir.path)) ?? []
        let maxN = files.compactMap { f -> Int? in
            let name = (f as NSString).deletingPathExtension
            return name.hasPrefix("메모") ? Int(name.dropFirst(2)) : nil
        }.max() ?? 0
        let url = notesDir.appendingPathComponent("메모\(maxN + 1).md")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        open(url)
        sidebar.refresh()
        window.makeFirstResponder(textView)
    }

    @objc func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        p.urls.forEach { open($0) }
    }

    @objc func addFolder() {
        setSidebar(true)
        sidebar.addFolder()
    }

    @objc func changeNotesDir() {
        guard let u = MainController.askNotesDir(first: false, current: notesDir.path) else { return }
        guard MainController.canWrite(u) else {
            _ = MainController.alert("이 폴더에 쓸 수 없습니다", u.path, ["확인"])
            return
        }
        notesDir = u
        state.notesDirChosen = true
        state.notesDir = u.path
        state.save()
        sidebar.setRoot(u)
        setSidebar(true)
    }

    @objc func saveNow() { doc?.save(); updateStatus() }

    @objc private func syntaxChanged() {
        guard let d = doc, d.media == nil, let s = Syntax.named(syntaxPopup.titleOfSelectedItem) else { return }
        d.syntax = s
        state.syntax[d.url.path] = s.name
        // 앱에서 만든 메모(기본 폴더)는 확장자도 같이 바꿈: 메모1.md → 메모1.json
        let ext = s.name == "Plain Text" ? "txt" : s.files.first ?? ""
        if !ext.isEmpty, !s.files.contains(d.url.pathExtension.lowercased()), !(ext == "txt" && d.url.pathExtension.lowercased() == "txt"),
           d.url.deletingLastPathComponent().standardizedFileURL == notesDir.standardizedFileURL {
            changeExtension(cur, to: ext)
        }
        s.apply(to: d.storage, base: baseAttrs)
        previewBtn.isHidden = !d.canPreview
        updateStatus()
        persist()
    }

    // MARK: 단축키 라우팅 — 터미널에 포커스가 있으면 터미널, 아니면 메모

    // 탐색기 포커스: ⌘W 추가 폴더 제거, ⌘⇧]/[·⌘1~9 폴더 탭 전환
    // ⌘T: 터미널이면 터미널 새 탭, 그 외(탐색기·에디터 = 상단 영역)는 항상 새 메모
    @objc func newTab() { terminalFocused ? terminal.newTab() : newNote() }
    @objc func closeTab() { sidebarFocused ? sidebar.removeCurrent() : terminalFocused ? terminal.closePane() : closeCurrent() }
    @objc func nextTab() { sidebarFocused ? sidebar.step(1) : terminalFocused ? terminal.step(1) : stepDoc(1) }
    @objc func prevTab() { sidebarFocused ? sidebar.step(-1) : terminalFocused ? terminal.step(-1) : stepDoc(-1) }
    @objc func selectTabN(_ sender: NSMenuItem) {
        if sidebarFocused { sidebar.selectRoot(sender.tag - 1) }
        else if terminalFocused { terminal.select(sender.tag - 1) }
        else if docs.indices.contains(sender.tag - 1) { select(sender.tag - 1) }
    }
    @objc func fontBigger() { changeFont(1) }
    @objc func fontSmaller() { changeFont(-1) }
    @objc func fontReset() { changeFont(nil) }

    @objc func splitVertical() { terminalVisible ? terminal.split(vertical: true) : setTerminal(true) }
    @objc func splitHorizontal() { terminalVisible ? terminal.split(vertical: false) : setTerminal(true) }
    @objc func nextPane() { terminal.stepPane(1) }
    @objc func prevPane() { terminal.stepPane(-1) }
    @objc func clearTerminal() { terminal.clear() }

    private func stepDoc(_ d: Int) { if !docs.isEmpty { select((cur + d + docs.count) % docs.count) } }

    private func changeFont(_ d: CGFloat?) {
        if terminalFocused { terminal.changeFont(d); return }
        if doc?.media != nil { zoom(d); return }    // PDF·이미지 탭은 ⌘+/⌘-/⌘0 = 확대/축소/맞춤
        state.editorFontSize = d.map { Double(max(9, editorSize + $0)) }
        for p in panes {
            p.textView.typingAttributes = baseAttrs
            p.ruler.fontSize = editorSize
            if let d = p.doc, d.media == nil { d.syntax.apply(to: d.storage, base: baseAttrs) }
        }
        state.save()
    }

    // MARK: PDF·이미지 확대 축소

    @objc func zoomIn() { zoom(1) }
    @objc func zoomOut() { zoom(-1) }
    @objc func zoomFit() { zoom(nil) }

    /// d: +1 확대, -1 축소, nil = 화면에 맞춤. 한 번에 1.25배
    private func zoom(_ d: CGFloat?) {
        let f: CGFloat = d.map { $0 > 0 ? 1.25 : 0.8 } ?? 1
        switch doc?.media {
        case .pdf?:
            if d == nil { pdfView.autoScales = true }
            else { pdfView.autoScales = false; pdfView.scaleFactor = min(max(pdfView.scaleFactor * f, 0.1), 10) }
        case .image?:
            let m = d == nil ? 1 : min(max(imageScroll.magnification * f, imageScroll.minMagnification), imageScroll.maxMagnification)
            let c = imageScroll.contentView.bounds
            imageScroll.setMagnification(m, centeredAt: NSPoint(x: c.midX, y: c.midY))
        case nil: return
        }
        updateZoomLabel()
    }

    /// 배율 표시. PDF = 실제 크기 대비, 이미지 = 창에 맞춘 크기 대비
    @objc private func updateZoomLabel() {
        let z: CGFloat
        switch doc?.media {
        case .pdf?: z = pdfView.scaleFactor
        case .image?: z = imageScroll.magnification
        case nil: return
        }
        zoomLabel.title = "\(Int((z * 100).rounded()))%"
    }
    var zoomText: String { zoomLabel.title }

    // MARK: 사이드바 / 터미널

    // MARK: 영역 포커스 (탐색기 → 메모 → 터미널, ⌘⌥← / ⌘⌥→)

    private enum Area: CaseIterable { case sidebar, editor, terminal }

    private var focusedArea: Area { sidebarFocused ? .sidebar : terminalFocused ? .terminal : .editor }

    private func updateFocusRing() {
        let a = focusedArea
        let dimOthers = sidebarVisible || terminalVisible
        rings.sidebar.set(focused: a == .sidebar, dimOthers: dimOthers)
        rings.editor.set(focused: a == .editor, dimOthers: dimOthers, showLine: !isSplit)
        // 분할 중 에디터에 포커스: 활성 칸 위에 민트 선, 다른 칸은 살짝 어둡게
        for (i, p) in panes.enumerated() { p.ring.set(focused: isSplit && a == .editor && i == active, dimOthers: isSplit && a == .editor) }
        rings.terminal.set(focused: a == .terminal, dimOthers: dimOthers)
    }

    /// 영역 안 아무 곳(탭 줄, 빈 곳, 이미지 등)을 클릭해도 그 영역으로 포커스
    func focusArea(clicked v: NSView) {
        if v is NSSplitView { return }  // 분할선 드래그
        if sidebarVisible, v.isDescendant(of: sidebar) {
            if !sidebarFocused { sidebar.focus() }
        } else if terminalVisible, v.isDescendant(of: terminal) {
            if !terminalFocused { terminal.focus(terminal.activeTerm) }
        } else if v.isDescendant(of: editorPane) || v.isDescendant(of: editorTabs) || v.isDescendant(of: headerRight) {
            let p = panes.first { v.isDescendant(of: $0) } ?? pane
            // 이미 에디터(같은 칸)면 그대로 — 탭 이름 변경 입력칸 등에서 포커스를 뺏지 않게
            if focusedArea == .editor, p === pane { return }
            if p.doc == nil { window.makeFirstResponder(nil); updateFocusRing() } else { window.makeFirstResponder(p.focusTarget) }
        }
    }

    @objc func focusNextArea() { moveFocus(1) }
    @objc func focusPrevArea() { moveFocus(-1) }

    /// 보이는 영역만 순환
    /// 탐색기 → 에디터 칸(분할 시 2개) → 터미널
    private func moveFocus(_ d: Int) {
        var targets: [() -> Void] = [], at = 0
        if sidebarVisible {
            if sidebarFocused { at = targets.count }
            targets.append { [unowned self] in sidebar.focus() }
        }
        for (i, p) in panes.enumerated() where editorVisible {
            if focusedArea == .editor, i == active { at = targets.count }
            targets.append { [unowned self] in
                if p.doc == nil { window.makeFirstResponder(nil); return }
                window.makeFirstResponder(p.focusTarget)
            }
        }
        if terminalVisible {
            if terminalFocused { at = targets.count }
            targets.append { [unowned self] in terminal.focus(terminal.activeTerm) }
        }
        targets[(at + d + targets.count) % targets.count]()
    }

    /// 메모 영역에서 실제로 보이는 뷰 (텍스트 / PDF / 이미지)
    private var editorFocusTarget: NSView { doc == nil ? emptyView : pane.focusTarget }

    // MARK: 집중 모드 (⌘⇧F) — 전체 화면일 때 상단 탭바 숨기기/보이기. 터미널에 포커스가 있으면 터미널만 남김

    private var chrome: [NSView] = []
    private var chromeTop: NSLayoutConstraint!, bareTop: NSLayoutConstraint!
    /// 켜기 전 상태 (끌 때 복원)
    private var focusMode: (sidebar: Bool, editor: Bool, terminalOnly: Bool)?
    var focusModeOn: Bool { focusMode != nil }
    var headerVisible: Bool { !(chrome.first?.isHidden ?? true) }
    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    @objc func toggleFocusMode() {
        if let f = focusMode {
            focusMode = nil
            setChrome(true)
            if f.editor { setEditor(true) }
            if f.sidebar { setSidebar(true) }
            if f.terminalOnly { terminal.focus(terminal.activeTerm) }
        } else {
            // 창 모드에서 헤더를 숨기면 신호등이 본문을 덮음 → 전체 화면에서만 (자가 점검은 화면을 뺏지 않으려고 창 모드로 확인)
            guard isFullScreen || isSelfTest else { NSSound.beep(); return }
            let termOnly = terminalVisible && terminalFocused
            focusMode = (sidebarVisible, editorVisible, termOnly)
            if termOnly { setSidebar(false); setEditor(false) }
            setChrome(false)
        }
    }

    private func setChrome(_ show: Bool) {
        chrome.forEach { $0.isHidden = !show }
        bareTop.isActive = !show
        chromeTop.isActive = show
    }

    /// 전체 화면에서는 빈 툴바(신호등 자리용)가 맨 위에 남아 헤더 탭을 가림 → 전체 화면 동안 숨김
    func windowWillEnterFullScreen(_ n: Notification) { window.toolbar?.isVisible = false }
    /// 전체 화면을 빠져나오면 툴바 복원 + 집중 모드도 끔 (헤더 없이 창 모드가 되지 않게)
    func windowDidExitFullScreen(_ n: Notification) {
        window.toolbar?.isVisible = true
        if focusMode != nil { toggleFocusMode() }
    }

    @objc func toggleSidebar() { setSidebar(!sidebarVisible) }
    @objc func toggleTerminal() { setTerminal(!terminalVisible) }
    @objc func toggleEditor() { setEditor(!editorVisible) }
    var editorVisible: Bool { editorPane.superview != nil }

    /// 에디터 숨기기: 터미널이 에디터 자리(탐색기 오른쪽)로 올라가 위아래를 다 씀.
    /// 둘 다 숨길 수는 없음 → 에디터를 숨기면 터미널은 켜고, 터미널을 숨기면 에디터가 다시 나옴
    private func setEditor(_ show: Bool) {
        guard show != editorVisible else { return }
        if !show, !terminalVisible { setTerminal(true) }
        let side = sidebarVisible ? sidebar.frame.width : 0
        terminal.removeFromSuperview()
        if show {
            mainSplit.addSubview(editorPane)
            rightSplit.addSubview(terminal)
        } else {
            editorPane.removeFromSuperview()
            mainSplit.addSubview(terminal)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        mainSplit.adjustSubviews()
        if sidebarVisible { mainSplit.setPosition(side, ofDividerAt: 0) }
        if show {
            rightSplit.adjustSubviews()
            rightSplit.setPosition(rightSplit.bounds.height / 2, ofDividerAt: 0)
        }
        editorOnlyHeader.forEach { $0.isHidden = !show }
        if show { if !sidebarFocused { window.makeFirstResponder(editorFocusTarget) } }
        else { terminal.focus(terminal.activeTerm) }
        updateFocusRing()
        state.editorHidden = !show
        state.save()
    }

    private func setSidebar(_ show: Bool) {
        if show, !sidebarVisible {
            let w = min(CGFloat(state.sidebarWidth ?? 250), (mainSplit.bounds.width * maxSidebarFraction).rounded(.down)) // 사용자가 조절한 너비 유지
            applyingSidebar = true
            mainSplit.addSubview(sidebar, positioned: .below, relativeTo: nil)
            window.contentView?.layoutSubtreeIfNeeded()
            mainSplit.adjustSubviews()
            mainSplit.setPosition(w, ofDividerAt: 0)
            mainSplit.setHoldingPriority(.init(260), forSubviewAt: 0) // 창 크기 바뀌어도 사이드바 너비 고정
            mainSplit.setHoldingPriority(.init(250), forSubviewAt: 1)
            applyingSidebar = false
            sidebar.refresh()
        } else if !show {
            sidebar.removeFromSuperview()
            mainSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        }
        alignTabs()
        updateFocusRing()
        state.sidebar = show
        state.save()
    }

    /// 첫 메모 탭의 글자가 에디터 본문 글자와 같은 x 에서 시작하도록
    private func alignTabs() {
        let editorX = sidebarVisible ? sidebar.frame.maxX + 1 : 0
        tabsLeading.constant = max(minTabsX, editorX + 12)
    }

    /// newTabAt: 탐색기 "터미널에서 열기" — 그 폴더에서 새 터미널 탭
    private func setTerminal(_ show: Bool, newTabAt dir: String? = nil) {
        if show, !terminalVisible {
            rightSplit.addSubview(terminal)
            // 실행 직후 복원 시 레이아웃 전이면 높이가 0 → 터미널이 전체를 덮던 문제. 먼저 레이아웃 확정.
            window.contentView?.layoutSubtreeIfNeeded()
            rightSplit.adjustSubviews()
            rightSplit.setPosition(rightSplit.bounds.height / 2, ofDividerAt: 0)
            if let dir { terminal.newTab(cwd: dir) }
            else if terminal.isEmpty { terminal.newTab() } else { terminal.focus(terminal.activeTerm) }
        } else if show, let dir {
            terminal.newTab(cwd: dir)
        } else if !show {
            setEditor(true)
            terminal.removeFromSuperview()
            window.makeFirstResponder(editorFocusTarget)
        }
        updateFocusRing()
        state.terminal = show
        state.save()
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { (panes.first { $0.textView === view }?.doc ?? doc)?.undo }

    func textDidChange(_ n: Notification) {
        doc?.dirty = true
        updateStatus()
        rulers.forEach { $0.updateWidth() }
        saveTimer?.invalidate()
        saveTimer = .scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.docs.forEach { $0.save() }; self?.updateStatus() }
        }
        highlightSoon()
    }

    func textViewDidChangeSelection(_ n: Notification) {
        updateStatus()
        for p in panes { p.textView.setNeedsDisplay(p.textView.visibleRect) } // 현재 줄 강조 다시 그림
        rulers.forEach { $0.redraw() }
    }

    private func highlightSoon() {
        hlTimer?.invalidate()
        hlTimer = .scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let d = self.doc, d.media == nil else { return }
                // 한글 조합 중에 속성을 건드리면 조합이 깨지므로 끝날 때까지 미룬다
                if self.editing.hasMarkedText() { self.highlightSoon(); return }
                d.syntax.apply(to: d.storage, base: self.baseAttrs)
            }
        }
    }
}
