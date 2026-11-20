import AppKit

/// 호버 시 옅은 배경 + 잠깐 뒤 설명 말풍선이 뜨는 아이콘 버튼 (기본 툴팁은 1초 넘게 걸려서 직접 띄움)
final class IconButton: NSButton {
    let tip: String
    /// 평소 아이콘 색 / 호버 시 색 (nil = 그대로)
    var tint = Theme.fgMuted { didSet { contentTintColor = tint } }
    var hoverTint: NSColor?
    private var hintWork: DispatchWorkItem?
    private static let hintLabel = label("", Theme.ui(11, 5), Theme.fg)
    private static let hintBox: NSView = {
        let v = NSView()
        v.style(bg: Theme.surface, border: Theme.border, radius: 6)
        v.pin(hintLabel, insets: .init(top: 4, left: 8, bottom: 4, right: 8))
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.4
        v.layer?.shadowRadius = 6
        return v
    }()

    init(_ symbol: String, _ tip: String, _ target: AnyObject?, _ action: Selector, size: CGFloat = 26, point: CGFloat = 13) {
        self.tip = tip
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: point, weight: .regular))
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = tint
        setAccessibilityLabel(tip)
        self.target = target
        self.action = action
        style(radius: Theme.rControl)
        _ = fixed(self, w: size, h: size)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) {
        layer?.backgroundColor = Theme.hover.cgColor
        if let hoverTint { contentTintColor = hoverTint }
        let w = DispatchWorkItem { [weak self] in self?.showHint() }
        hintWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }
    override func mouseExited(with e: NSEvent) { layer?.backgroundColor = nil; contentTintColor = tint; hideHint() }
    override func mouseDown(with e: NSEvent) { hideHint(); super.mouseDown(with: e) }
    override func viewDidMoveToWindow() { if window == nil { hideHint() } }

    /// 버튼 아래(공간 없으면 위)에 설명을 띄움
    func showHint() {
        guard let root = window?.contentView, !tip.isEmpty else { return }
        let box = Self.hintBox
        Self.hintLabel.stringValue = tip
        box.removeFromSuperview()
        root.addSubview(box)
        let size = box.fittingSize, r = convert(bounds, to: root)
        var y = r.minY - size.height - 6
        if y < 4 { y = r.maxY + 6 }
        let x = min(max(6, r.midX - size.width / 2), root.bounds.width - size.width - 6)
        box.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        box.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; box.animator().alphaValue = 1 }
    }
    func hideHint() {
        hintWork?.cancel()
        hintWork = nil
        if Self.hintBox.superview != nil, Self.hintLabel.stringValue == tip { Self.hintBox.removeFromSuperview() }
    }
    static var hintShowing: String? { hintBox.superview == nil ? nil : hintLabel.stringValue }
}

/// 둥근 탭 하나. 선택 = 은은한 민트빛 그라데이션 + 옅은 테두리, 나머지는 글자만 (호버 시 옅은 배경)
final class PillTab: NSView, NSTextFieldDelegate {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private let selected: Bool
    private let close: IconButton?
    private var titleLabel: NSTextField!
    private var commit: ((String) -> Void)?
    private var cancelled = false
    private var editWidth: NSLayoutConstraint?

    /// 글자 수 제한으로 잘린 탭이면 전체 이름 (호버 시 펼침)
    private var fullTitle: String?, shortTitle = ""

    init(_ title: String, tip: String, selected: Bool, closable: Bool, icon: NSImage? = nil, maxChars: Int? = nil, secondary: Bool = false) {
        self.selected = selected
        close = closable ? IconButton("xmark", "닫기", nil, #selector(NSText.cut(_:)), size: 16, point: 8) : nil
        super.init(frame: .zero)
        toolTip = tip
        var shown = title
        if let n = maxChars, title.count > n { fullTitle = title; shown = String(title.prefix(n)) + "…" }
        shortTitle = shown
        let l = label(shown, Theme.ui(12, selected ? 6 : 5), selected ? Theme.fg : Theme.fgMuted)
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        titleLabel = l
        let row = NSStackView(views: [l])
        row.spacing = 4
        if let icon {
            let iv = NSImageView(image: icon)
            iv.alphaValue = selected ? 1 : 0.7
            _ = fixed(iv, w: 14, h: 14)
            row.insertArrangedSubview(iv, at: 0)
            row.setCustomSpacing(5, after: iv)
        }
        if let close {
            close.target = self
            close.action = #selector(closeTapped)
            close.alphaValue = selected ? 1 : 0
            row.addArrangedSubview(close)
        }
        pin(row, insets: .init(top: 0, left: 12, bottom: 0, right: close == nil ? 12 : 5))
        _ = fixed(self, h: 26)
        style(radius: 8)
        if selected {
            grad.colors = [Theme.rgb(0x3A4A42).cgColor, Theme.rgb(0x2B312E).cgColor]   // 위 → 아래
            grad.cornerRadius = 8
            grad.borderWidth = 1
            grad.borderColor = Theme.accent.withAlphaComponent(0.22).cgColor
            layer?.insertSublayer(grad, at: 0) // 글자 아래
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 3
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        } else if secondary {
            // 분할된 다른 쪽 패널에 떠 있는 탭: 옅은 민트 테두리만
            layer?.borderWidth = 1
            layer?.borderColor = Theme.accent.withAlphaComponent(0.35).cgColor
            l.textColor = Theme.fg
        }
    }
    private let grad = CAGradientLayer()
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grad.frame = bounds
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, onDoubleClick != nil { onDoubleClick?() } else { onClick?() }
    }

    /// 탭 이름을 그 자리에서 편집. Enter/포커스 이동 = 확정, Esc = 취소
    func beginEdit(_ text: String, commit: @escaping (String) -> Void) {
        self.commit = commit
        cancelled = false
        titleLabel.stringValue = text
        titleLabel.isEditable = true
        titleLabel.isSelectable = true
        titleLabel.focusRingType = .none
        titleLabel.delegate = self
        editWidth = titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        editWidth?.isActive = true
        window?.makeFirstResponder(titleLabel)
        titleLabel.currentEditor()?.selectAll(nil)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        window?.makeFirstResponder(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        titleLabel.isEditable = false
        editWidth?.isActive = false
        let done = commit
        commit = nil
        if !cancelled { done?(titleLabel.stringValue.trimmingCharacters(in: .whitespaces)) }
    }
    override func otherMouseDown(with e: NSEvent) { if close != nil { onClose?() } } // 휠 클릭 닫기

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    private func setExpanded(_ on: Bool) {
        guard let full = fullTitle, !titleLabel.isEditable else { return }
        titleLabel.stringValue = on ? full : shortTitle
        var v = superview
        while v != nil, !(v is PillTabBar) { v = v?.superview }
        v?.invalidateIntrinsicContentSize()
    }
    override func mouseEntered(with e: NSEvent) {
        setExpanded(true)
        close?.alphaValue = 1
        if !selected { layer?.backgroundColor = Theme.rgb(0xFFFFFF, 0.05).cgColor }
    }
    override func mouseExited(with e: NSEvent) {
        setExpanded(false)
        if !selected { close?.alphaValue = 0; layer?.backgroundColor = nil }
    }
}

/// 가로 스크롤되는 알약 탭 바 (에디터 / 터미널 / 사이드바 폴더 공용)
final class PillTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var isClosable: (Int) -> Bool = { _ in true }
    var menuFor: ((Int) -> NSMenu?)?
    /// 이름 편집: 편집할 초기 글자 / 확정 시 호출. 둘 다 있으면 더블클릭으로 편집 시작
    var editText: ((Int) -> String)?
    var onRename: ((Int, String) -> Void)?
    /// 이름 편집이 없는 바에서 더블클릭 동작
    var onDoubleClick: ((Int) -> Void)?
    var iconFor: ((Int) -> NSImage?)?
    var maxChars: Int?
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false // 투명 타이틀바 인셋 때문에 탭이 위로 밀리는 것 방지
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        pin(scroll)
        _ = fixed(self, h: 28)
        setContentHuggingPriority(.init(10), for: .horizontal)
        setContentCompressionResistancePriority(.init(10), for: .horizontal)
    }
    /// 탭들 너비만큼 (공간이 모자라면 줄어들고 가로 스크롤) → 바로 뒤의 + 버튼이 마지막 탭에 붙음
    override var intrinsicContentSize: NSSize { NSSize(width: stack.fittingSize.width, height: 28) }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ items: [(title: String, tip: String)], selected: Int, secondary: Int? = nil) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, it) in items.enumerated() {
            let t = PillTab(it.title, tip: it.tip, selected: i == selected, closable: isClosable(i), icon: iconFor?(i), maxChars: maxChars,
                            secondary: i == secondary && i != selected)
            t.onClick = { [weak self] in self?.onSelect?(i) }
            t.onClose = { [weak self] in self?.onClose?(i) }
            t.contextMenu = { [weak self] in self?.menuFor?(i) }
            if editText != nil { t.onDoubleClick = { [weak self] in self?.beginEdit(i) } }
            else if onDoubleClick != nil { t.onDoubleClick = { [weak self] in self?.onDoubleClick?(i) } }
            stack.addArrangedSubview(t)
        }
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
        if stack.arrangedSubviews.indices.contains(selected) {
            let v = stack.arrangedSubviews[selected]
            v.scrollToVisible(v.bounds)
        }
    }

    func beginEdit(_ i: Int) {
        guard let text = editText?(i), let t = stack.arrangedSubviews[safe: i] as? PillTab else { return }
        t.beginEdit(text) { [weak self] in self?.onRename?(i, $0) }
    }
}

/// 상단 헤더: 빈 곳 드래그 = 창 이동, 더블클릭 = 확대
final class HeaderView: NSView {
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
    }
}

/// 1px 구분선이지만 잡는 영역은 위아래 4px 씩 넓힘, 양쪽 최소 크기 보장
final class ThinSplit: NSSplitView, NSSplitViewDelegate {
    var minSize: CGFloat = 90
    /// 첫 칸 최대 비율 (사이드바 35%)
    var maxFirstFraction: CGFloat?
    var onResize: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); delegate = self; dividerStyle = .thin }
    required init?(coder: NSCoder) { fatalError() }
    override var dividerColor: NSColor { Theme.border }
    override var dividerThickness: CGFloat { 1 }

    func splitView(_ s: NSSplitView, additionalEffectiveRectOfDividerAt i: Int) -> NSRect {
        let r = arrangedSubviews[i].frame
        return isVertical ? NSRect(x: r.maxX - 4, y: 0, width: 9, height: bounds.height)
                          : NSRect(x: 0, y: r.maxY - 4, width: bounds.width, height: 9)
    }
    func splitViewDidResizeSubviews(_ n: Notification) { onResize?() }
    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p + minSize }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        guard i == 0, let f = maxFirstFraction else { return p - minSize }
        return min(p - minSize, (isVertical ? bounds.width : bounds.height) * f)
    }
}

/// 첫 응답자 변경을 알려주는 창 (터미널 활성 패널 추적용)
final class AppWindow: NSWindow {
    var onResponderChange: ((NSResponder?) -> Void)?
    override func makeFirstResponder(_ r: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(r)
        if ok { onResponderChange?(r) }
        return ok
    }
    /// ⌃⇥ / ⌃⇧⇥ = 다음 / 이전 탭 (+1 / -1). 텍스트 뷰·터미널보다 먼저 가로챔
    var onCtrlTab: ((Int) -> Void)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.type == .keyDown, e.keyCode == 48, m == .control || m == [.control, .shift], let f = onCtrlTab {
            f(m.contains(.shift) ? -1 : 1); return true
        }
        return super.performKeyEquivalent(with: e)
    }
    /// 마우스 클릭한 뷰 (영역 포커스용). 클릭 처리가 끝난 뒤 알림
    var onMouseDown: ((NSView) -> Void)?
    override func sendEvent(_ e: NSEvent) {
        let hit = e.type == .leftMouseDown || e.type == .rightMouseDown ? contentView?.superview?.hitTest(e.locationInWindow) : nil
        super.sendEvent(e)
        if let hit { onMouseDown?(hit) }
    }
}

/// 창 전체 드롭 영역: 앱 밖에서 끌어온 파일/폴더를 받음 (에디터·터미널은 각자 처리)
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    init() { super.init(frame: .zero); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    private func urls(_ s: NSDraggingInfo) -> [URL] {
        guard s.draggingSource == nil else { return [] } // 탐색기에서 끌어온 건 무시
        return s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { urls(s).isEmpty ? [] : .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let list = urls(s)
        guard !list.isEmpty else { return false }
        onDrop?(list)
        return true
    }
}

/// 영역 포커스 표시 (iTerm/Warp 의 "비활성 패널 흐리게" + VS Code 활성 탭 윗선):
/// 포커스 없는 영역은 살짝 어둡게, 포커스 영역은 그대로 + 맨 위에 민트 선(오른쪽으로 옅어짐). 클릭은 통과.
final class FocusRing: NSView {
    private let dim = CALayer(), line = CAGradientLayer()
    private(set) var isFocused = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        dim.opacity = 0
        line.colors = [Theme.accent.cgColor, Theme.accent.withAlphaComponent(0.35).cgColor, Theme.accent.withAlphaComponent(0).cgColor]
        line.locations = [0, 0.5, 1]
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        line.opacity = 0
        layer?.addSublayer(dim)
        layer?.addSublayer(line)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        line.frame = CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        CATransaction.commit()
    }

    /// dimOthers: 보이는 영역이 하나뿐이면 흐리게 할 필요 없음
    func set(focused: Bool, dimOthers: Bool, showLine: Bool = true) {
        isFocused = focused
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        line.opacity = focused && showLine ? 1 : 0
        dim.opacity = !focused && dimOthers ? 1 : 0
        CATransaction.commit()
    }

    /// 대상 뷰의 맨 위에 꽉 차게 붙임
    func attach(to v: NSView) { v.pin(self) }
}

final class SoftRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Theme.rControl, yRadius: Theme.rControl).fill()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// 클로저로 동작하는 메뉴 항목 (우클릭 메뉴용)
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
