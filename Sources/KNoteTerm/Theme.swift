import AppKit

/// 다크 고정. 색감은 CotEditor "Anura (Dark)" (배경 #1F1F1F, 글자 #E5E5E5), 포인트는 DESIGN.md 민트.
enum Theme {
    static func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
    }
    static let accent = rgb(0x72E3AD)                 // mint
    static let accentBorder = rgb(0x17B674, 0.75)
    static let fg = rgb(0xE5E5E5)                     // Anura text
    static let fgMuted = rgb(0xA8A8A8)                // Anura insertionPoint
    static let fgSubtle = rgb(0xFFFFFF, 0.45)
    static let bg = rgb(0x1F1F1F)                     // Anura background — 에디터 / 헤더
    static let surface = rgb(0x333333)                // 선택 탭, 팝업 (Anura lineHighlight 톤)
    static let sunken = rgb(0x262626)                 // 사이드바, 터미널 헤더 (에디터보다 살짝 밝게)
    static let hover = rgb(0xFFFFFF, 0.07)
    static let hairline = rgb(0xFFFFFF, 0.08)
    static let border = rgb(0x4A4A4A)
    static let selection = rgb(0x72E3AD, 0.25)
    static let lineHighlight = rgb(0x333333, 0.7)     // Anura lineHighlight #333333b3
    static let focusRing = rgb(0x72E3AD, 0.45)        // 포커스 영역 테두리 (은은하게)
    static let rControl: CGFloat = 6, rOverlay: CGFloat = 8

    /// weight: NSFontManager 단위 (5 = Regular, 6 = Medium, 8 = SemiBold)
    static func ui(_ size: CGFloat, _ weight: Int = 5) -> NSFont {
        NSFontManager.shared.font(withFamily: "Inter", traits: [], weight: weight, size: size)
            ?? .systemFont(ofSize: size, weight: weight >= 6 ? .medium : .regular)
    }
    static func mono(_ size: CGFloat) -> NSFont {
        NSFontManager.shared.font(withFamily: "Source Code Pro", traits: [], weight: 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension NSView {
    func style(bg: NSColor? = nil, border: NSColor? = nil, radius: CGFloat = 0) {
        wantsLayer = true
        layer?.backgroundColor = bg?.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
        layer?.cornerRadius = radius
    }

    func pin(_ v: NSView, insets: NSEdgeInsets = .init()) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// 세로 배치: 모든 자식을 좌우 꽉 채우고 위→아래로 이어 붙임. stretch 인덱스의 뷰가 남는 높이를 가짐.
func column(_ views: [NSView], insets: NSEdgeInsets = .init(), spacing: CGFloat = 0) -> NSView {
    let c = NSView()
    var prev: NSView?
    for v in views {
        v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: insets.left),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -insets.right),
            prev.map { v.topAnchor.constraint(equalTo: $0.bottomAnchor, constant: spacing) }
                ?? v.topAnchor.constraint(equalTo: c.topAnchor, constant: insets.top),
        ])
        prev = v
    }
    prev?.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -insets.bottom).isActive = true
    return c
}

func hairline() -> NSView {
    let v = NSView()
    v.style(bg: Theme.hairline)
    v.translatesAutoresizingMaskIntoConstraints = false
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
}

func label(_ s: String, _ font: NSFont, _ color: NSColor = Theme.fgMuted) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

func fixed(_ v: NSView, w: CGFloat? = nil, h: CGFloat? = nil) -> NSView {
    v.translatesAutoresizingMaskIntoConstraints = false
    if let w { v.widthAnchor.constraint(equalToConstant: w).isActive = true }
    if let h { v.heightAnchor.constraint(equalToConstant: h).isActive = true }
    return v
}

func spacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return v
}
