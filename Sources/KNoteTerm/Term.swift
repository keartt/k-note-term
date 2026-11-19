import AppKit

/// 드롭된 파일들의 절대경로 텍스트. 파일시스템이 주는 한글은 자모 분해(NFD)라
/// 그대로 셸에 보내면 zsh 입력줄 폭 계산이 틀어져 깨짐 → NFC 로 합친다.
func dropText(_ urls: [URL], shell: Bool) -> String {
    let paths = urls.map { $0.path.precomposedStringWithCanonicalMapping }
    return shell ? paths.map(shellEscape).joined(separator: " ") + " " : paths.joined(separator: "\n")
}

func shellEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        if " ()'\"&;|<>$`\\!*?[]{}#~".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

/// 하단 터미널 영역: 탭 + 탭마다 분할 패널 트리 (GhosttyTerm 또는 중첩 ThinSplit)
final class TerminalArea: NSView {
    var onEmpty: (() -> Void)?
    private let bar = PillTabBar()
    private let content = NSView()
    private var tabs: [NSView] = []
    private var sel = 0
    private var names: [String?] = []   // 탭 별칭 (tabs 와 같은 순서)
    private weak var active: GhosttyTerm?

    var isEmpty: Bool { tabs.isEmpty }
    var tabCount: Int { tabs.count }
    var paneCount: Int { current.map { terms(in: $0).count } ?? 0 }
    private var current: NSView? { tabs.indices.contains(sel) ? tabs[sel] : nil }
    var activeTerm: GhosttyTerm? {
        if let a = active, let c = current, a.isDescendant(of: c) { return a }
        return current.flatMap { terms(in: $0).first }
    }

    init() {
        super.init(frame: .zero)
        bar.onSelect = { [weak self] in self?.select($0) }
        bar.onClose = { [weak self] in self?.closeTab($0) }
        // 탭 별칭: 더블클릭 또는 우클릭 > 이름 지정. 비우면 자동 이름(현재 폴더)으로
        bar.editText = { [weak self] i in self?.tabTitle(i) ?? "" }
        bar.onRename = { [weak self] i, name in self?.setName(i, name) }
        bar.menuFor = { [weak self] i in self?.tabMenu(i) }
        let header = NSStackView(views: [
            bar,
            IconButton("plus", "새 터미널 탭 (⌘T)", self, #selector(newTabAction)),
            IconButton("rectangle.split.2x1", "세로 분할 (⌘D)", self, #selector(splitVertical)),
            IconButton("rectangle.split.1x2", "가로 분할 (⌘⇧D)", self, #selector(splitHorizontal)),
            IconButton("chevron.down", "터미널 숨기기 (⌘⇧T)", nil, #selector(MainController.toggleTerminal)),
        ])
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        header.style(bg: Theme.sunken)
        _ = fixed(header, h: 36)
        content.style(bg: Theme.bg)
        content.setContentHuggingPriority(.init(1), for: .vertical)
        content.setContentCompressionResistancePriority(.init(1), for: .vertical)
        pin(column([header, hairline(), content]))
    }
    required init?(coder: NSCoder) { fatalError() }

    func terms(in v: NSView) -> [GhosttyTerm] {
        if let t = v as? GhosttyTerm { return [t] }
        return v.subviews.flatMap(terms)
    }

    func noteFocus(_ r: NSResponder?) {
        if let t = r as? GhosttyTerm, t.isDescendant(of: self) { active = t }
    }

    func focus(_ t: GhosttyTerm?) {
        guard let t else { return }
        active = t
        window?.makeFirstResponder(t)
    }

    @objc func newTabAction() { newTab(cwd: nil) }
    func newTab() { newTab(cwd: nil) }

    /// cwd 없으면 현재 패널의 작업 폴더를 이어받음
    func newTab(cwd: String?) {
        let t = makeTerm(inherit: cwd == nil ? activeTerm : nil, split: false, cwd: cwd)
        tabs.append(t)
        names.append(nil)
        show(tabs.count - 1)
        focus(t)
    }

    func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        show(i)
        focus(activeTerm)
    }

    func step(_ d: Int) { if !tabs.isEmpty { select((sel + d + tabs.count) % tabs.count) } }

    func stepPane(_ d: Int) {
        guard let c = current, let a = activeTerm else { return }
        let all = terms(in: c), i = all.firstIndex { $0 === a } ?? 0
        focus(all[(i + d + all.count) % all.count])
    }

    @objc func splitVertical() { split(vertical: true) }
    @objc func splitHorizontal() { split(vertical: false) }

    /// 활성 패널을 [기존 | 새 패널] 분할 뷰로 교체 (분할은 항상 2개짜리로 중첩)
    func split(vertical: Bool) {
        guard let a = activeTerm, let parent = a.superview else { newTab(); return }
        let t = makeTerm(inherit: a, split: true, cwd: nil), sp = ThinSplit()
        sp.isVertical = vertical
        sp.frame = a.frame
        sp.autoresizingMask = a.autoresizingMask
        if let i = tabs.firstIndex(where: { $0 === a }) { tabs[i] = sp }
        parent.replaceSubview(a, with: sp)
        sp.addSubview(a)
        sp.addSubview(t)
        sp.adjustSubviews()
        sp.setPosition((vertical ? sp.bounds.width : sp.bounds.height) / 2, ofDividerAt: 0)
        focus(t)
    }

    func closePane() {
        guard let t = activeTerm else { return }
        t.kill()
        remove(t)
    }

    func closeTab(_ i: Int) {
        terms(in: tabs[i]).forEach { $0.kill() }
        dropTab(i)
    }

    func clear() { activeTerm?.clear() }

    func changeFont(_ d: CGFloat?) {
        let a = d == nil ? "reset_font_size" : d! > 0 ? "increase_font_size:1" : "decrease_font_size:1"
        tabs.flatMap(terms).forEach { $0.action(a) }
    }

    // MARK: 내부

    private func makeTerm(inherit: GhosttyTerm?, split: Bool, cwd: String?) -> GhosttyTerm {
        let t = GhosttyTerm(inherit: inherit, split: split, cwd: cwd)
        t.onExit = { [weak self, weak t] in if let t { self?.remove(t) } }
        t.onTitle = { [weak self] in self?.reloadBar() }
        return t
    }

    private func show(_ i: Int) {
        sel = i
        content.subviews.forEach { $0.removeFromSuperview() }
        let v = tabs[i]
        v.frame = content.bounds // 여백은 ghostty window-padding
        v.autoresizingMask = [.width, .height]
        content.addSubview(v)
        reloadBar()
    }

    private func dropTab(_ i: Int) {
        let shown = current
        tabs.remove(at: i)
        names.remove(at: i)
        if tabs.isEmpty {
            content.subviews.forEach { $0.removeFromSuperview() }
            onEmpty?()
        } else if let shown, let j = tabs.firstIndex(where: { $0 === shown }) {
            sel = j
            reloadBar()
        } else {
            select(min(i, tabs.count - 1))
        }
    }

    private func remove(_ t: GhosttyTerm) {
        if let i = tabs.firstIndex(where: { $0 === t }) { dropTab(i); return }
        guard let sp = t.superview as? NSSplitView else { return }
        t.removeFromSuperview()
        // 남은 하나로 분할 뷰를 대체
        guard let other = sp.subviews.first else { return }
        other.removeFromSuperview()
        other.frame = sp.frame
        other.autoresizingMask = sp.autoresizingMask
        if let i = tabs.firstIndex(where: { $0 === sp }) { tabs[i] = other }
        sp.superview?.replaceSubview(sp, with: other)
        if let c = current, other.isDescendant(of: c) { focus(terms(in: other).first) }
        reloadBar()
    }

    /// 사용자가 붙인 별칭이 있으면 그것, 없으면 셸이 알려준 제목(현재 폴더)
    func tabTitle(_ i: Int) -> String {
        if let n = names[safe: i] ?? nil { return n }
        let t = tabs[safe: i].flatMap { terms(in: $0).first?.title } ?? ""
        return t.isEmpty ? "터미널 \(i + 1)" : t
    }

    var tabTitles: [String] { tabs.indices.map(tabTitle) }
    func beginRename(_ i: Int) { bar.beginEdit(i) }

    func setName(_ i: Int, _ name: String) {
        guard names.indices.contains(i) else { return }
        names[i] = name.isEmpty ? nil : name
        reloadBar()
        focus(activeTerm)
    }

    private func tabMenu(_ i: Int) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("이름 지정") { [weak self] in self?.select(i); self?.bar.beginEdit(i) })
        if names[safe: i] ?? nil != nil { m.addItem(ClosureMenuItem("이름 지우기") { [weak self] in self?.setName(i, "") }) }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("탭 닫기") { [weak self] in self?.closeTab(i) })
        return m
    }

    private func reloadBar() {
        bar.set(tabs.enumerated().map { i, v in
            let n = terms(in: v).count, name = tabTitle(i)
            return (n > 1 ? "\(name) (\(n))" : name, terms(in: v).first?.pwd ?? name)
        }, selected: sel)
    }
}
