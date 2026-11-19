// 앱 아이콘 생성: swift scripts/make-icon.swift [out.png] → 1024 PNG (icns 변환은 아래 주석 참고)
// 노트 + 터미널: 큰 민트 >  / 오른쪽 회색 노트 줄 세 개 / 맨 아래 _ 가 오른쪽 끝까지 (민트 → 회색, 포커스 윗선처럼)
//   mkdir AppIcon.iconset && for s in 16 32 128 256 512; do sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png;
//   sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png; done && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let S: CGFloat = 1024
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}
let mint = rgb(0x72E3AD), gray = rgb(0x5E6461)

/// 경로 모양 안을 그라데이션으로 채움 (stroke: 선 두께로 만든 외곽을 채움)
func fill(_ path: NSBezierPath, _ g: NSGradient, angle: CGFloat, glow: NSColor? = nil, blur: CGFloat = 0) {
    if let glow {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = glow
        sh.shadowBlurRadius = blur
        sh.set()
        NSColor.black.setFill()
        path.fill()   // 그림자(빛)만 쓰고 본체는 아래 그라데이션이 덮음
        NSGraphicsContext.restoreGraphicsState()
    }
    g.draw(in: path, angle: angle)
}
func stroked(_ path: NSBezierPath) -> NSBezierPath {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.addPath(path.cgPath)
    ctx.setLineWidth(path.lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    let out = NSBezierPath(cgPath: ctx.path!)
    ctx.restoreGState()
    return out
}

func draw() {
    // 바탕: macOS 아이콘 그리드 (824, 모서리 185), 짙은 회색 → 검정
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let card = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = .black.withAlphaComponent(0.45)
    sh.shadowBlurRadius = 28
    sh.shadowOffset = NSSize(width: 0, height: -12)
    sh.set()
    rgb(0x1C1C1C).setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0x2C2F2E), ending: rgb(0x0D0E0E))!.draw(in: card, angle: -90)
    // 기호 뒤로 은은한 민트 빛
    NSGraphicsContext.saveGraphicsState()
    card.addClip()
    NSGradient(starting: mint.withAlphaComponent(0.16), ending: mint.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: 440, y: 540), radius: 0, toCenter: NSPoint(x: 440, y: 540), radius: 420, options: [])
    NSGraphicsContext.restoreGraphicsState()
    // 유리 테두리: 위는 밝게, 아래로 사라짐
    card.lineWidth = 5
    NSGradient(colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0.04), rgb(0xFFFFFF, 0.08)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(in: stroked(card), angle: -90)

    // 기호들은 가운데로 모아 여백을 둠
    let t = NSAffineTransform()
    t.translateX(by: 512, yBy: 512)
    t.scale(by: 0.6)
    t.translateX(by: -497, yBy: -528)
    t.concat()

    // > : 위 밝은 민트 → 아래 짙은 민트, 바깥으로 빛
    let chev = NSBezierPath()
    chev.move(to: NSPoint(x: 200, y: 800))
    chev.line(to: NSPoint(x: 430, y: 590))
    chev.line(to: NSPoint(x: 200, y: 380))
    chev.lineWidth = 80
    fill(stroked(chev), NSGradient(starting: rgb(0xB4F7D6), ending: rgb(0x34BE82))!, angle: -90,
         glow: mint.withAlphaComponent(0.55), blur: 50)

    // 노트 줄 세 개: 왼쪽 살짝 밝게 → 회색 (= 아래 _ 의 오른쪽 끝 색)
    let lineG = NSGradient(starting: rgb(0x8A918D), ending: gray)!
    for (y, w) in [(760, 290), (630, 290), (500, 200)] as [(CGFloat, CGFloat)] {
        fill(NSBezierPath(roundedRect: NSRect(x: 540, y: y, width: w, height: 42), xRadius: 21, yRadius: 21), lineG, angle: 0)
    }

    // _ : 왼쪽 진한 민트 → 오른쪽 회색, 오른쪽 끝까지
    let bar = NSBezierPath(roundedRect: NSRect(x: 200, y: 220, width: 630, height: 76), xRadius: 38, yRadius: 38)
    fill(bar, NSGradient(colors: [rgb(0x8AF0C0), mint.blended(withFraction: 0.55, of: gray)!, gray], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!,
         angle: 0, glow: mint.withAlphaComponent(0.35), blur: 36)
    // 윗면 광택
    NSGraphicsContext.saveGraphicsState()
    for p in [bar, stroked(chev)] {
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGradient(starting: rgb(0xFFFFFF, 0.28), ending: rgb(0xFFFFFF, 0))!.draw(in: p.bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
draw()
NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
