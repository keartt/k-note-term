import AppKit

/// 미리보기용 최소 마크다운 → HTML (GFM 자주 쓰는 것만: 제목, 목록/체크박스, 인용, 코드블록, 표, 구분선, 인라인)
enum Markdown {
    /// base = 원문에서 첫 줄의 줄 번호 (인용 안쪽을 다시 변환할 때 체크박스 줄 번호를 맞추려고)
    static func html(_ src: String, base: Int = 0) -> String {
        var out = "", para: [String] = []
        var lists: [(indent: Int, tag: String)] = []   // 열린 목록 (각각 마지막 <li> 가 열려 있음)
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushPara() { if !para.isEmpty { out += "<p>\(para.map(inline).joined(separator: "<br>"))</p>\n"; para = [] } }
        func closeLists() { while let l = lists.popLast() { out += "</li></\(l.tag)>\n" } }
        func flush() { flushPara(); closeLists() }
        func indent(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }
        func cells(_ s: String) -> [String] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        while i < lines.count {
            let line = lines[i], t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {               // 코드 블록
                flush()
                let fence = String(t.prefix(3)), lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                out += codeBlock(code.joined(separator: "\n"), lang: lang)
            } else if t.isEmpty {
                flushPara()   // 빈 줄로 목록을 끊지 않음 (항목 사이 빈 줄)
            } else if let m = t.firstMatch(of: /^(#{1,6})\s+(.*?)\s*#*$/) {
                flush()
                out += "<h\(m.1.count)>\(inline(String(m.2)))</h\(m.1.count)>\n"
            } else if t.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
                flush(); out += "<hr>\n"
            } else if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                let qStart = i
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var s = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if s.hasPrefix(" ") { s = s.dropFirst() }
                    q.append(String(s)); i += 1
                }
                out += "<blockquote>\(html(q.joined(separator: "\n"), base: base + qStart))</blockquote>\n"
                continue
            } else if t.contains("|"), i + 1 < lines.count,
                      lines[i + 1].trimmingCharacters(in: .whitespaces).wholeMatch(of: /\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?/) != nil {
                flush()
                out += "<table><thead><tr>" + cells(t).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>\n"
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    out += "<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"; i += 1
                }
                out += "</tbody></table>\n"
                continue
            } else if let m = line.firstMatch(of: /^[ \t]*([-*+]|(\d+)[.)])\s+(.*)$/) {
                // 목록: 들여쓰기 2칸 이상 깊으면 안쪽 목록, 같은 깊이면 다음 항목
                flushPara()
                let ind = indent(line), tag = m.2 == nil ? "ul" : "ol"
                while let l = lists.last, l.indent > ind + 1 { out += "</li></\(l.tag)>\n"; lists.removeLast() }
                var open = true
                if let l = lists.last, ind <= l.indent + 1 {
                    if l.tag == tag { out += "</li>\n"; open = false } else { out += "</li></\(l.tag)>\n"; lists.removeLast() }
                }
                if open {
                    let start = m.2.flatMap { Int($0) }.map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
                    out += "<\(tag)\(start)>\n"; lists.append((ind, tag))
                }
                var body = String(m.3), cls = ""
                if let c = body.firstMatch(of: /^\[([ xX])\]\s+(.*)$/) {
                    cls = " class=\"task\""
                    body = "<input type=\"checkbox\" data-line=\"\(base + i)\"\(c.1 == " " ? "" : " checked")> " + inline(String(c.2))
                } else { body = inline(body) }
                out += "<li\(cls)>\(body)"
            } else if !lists.isEmpty, indent(line) > 0 {
                out += "<br>" + inline(t)                               // 목록 항목의 이어지는 줄
            } else if para.isEmpty, indent(line) >= 4 {                 // 들여쓴 코드 블록
                flush()
                var code: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || indent(lines[i]) >= 4 {
                    var l = Substring(lines[i]), n = 0
                    while n < 4, let c = l.first, c == " " || c == "\t" { n += c == "\t" ? 4 : 1; l = l.dropFirst() }
                    code.append(String(l)); i += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                out += codeBlock(code.joined(separator: "\n"), lang: "")
                continue
            } else {
                closeLists()
                para.append(t)
            }
            i += 1
        }
        flush()
        return out
    }

    /// 코드 블록: 언어가 앱 문법에 있으면 같은 색으로 칠함 + 오른쪽 위 복사 버튼
    static func codeBlock(_ code: String, lang: String) -> String {
        "<div class=\"code\"><pre><code class=\"lang-\(esc(lang))\">\(highlight(code, lang: lang))</code></pre>"
            + "<button class=\"copy\" onclick=\"copyCode(this)\">복사</button></div>\n"
    }

    static func highlight(_ code: String, lang: String) -> String {
        guard let syn = Syntax.forLang(lang) else { return esc(code) }
        let ns = code as NSString
        var col = [NSColor?](repeating: nil, count: ns.length)
        for (r, c) in syn.colorRuns(code) { for k in r.location..<NSMaxRange(r) { col[k] = c } }
        var out = "", a = 0
        while a < ns.length {
            var b = a + 1
            while b < ns.length, col[b] === col[a] { b += 1 }
            let t = esc(ns.substring(with: NSRange(location: a, length: b - a)))
            out += col[a].map { "<span style=\"color:\(hex($0))\">\(t)</span>" } ?? t
            a = b
        }
        return out
    }

    static func hex(_ c: NSColor) -> String {
        let c = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    // Swift Regex 는 lookbehind 미지원 → ICU
    private static let em = try! NSRegularExpression(pattern: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\*)|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#)

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 인라인: `코드` 는 먼저 빼 두고(안쪽은 변환 안 함) 나머지에 이미지/링크/강조 적용
    static func inline(_ s: String) -> String {
        var codes: [String] = []
        var t = esc(s).replacing(/`([^`]+)`/) { m in codes.append("<code>\(m.1)</code>"); return "\u{0}\(codes.count - 1)\u{0}" }
        t = t.replacing(/!\[([^\]]*)\]\(([^)\s]+)\)/) { "<img alt=\"\($0.1)\" src=\"\($0.2)\">" }
        t = t.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        t = t.replacing(/(^|[\s(])(https?:\/\/[^\s<]+)/) { "\($0.1)<a href=\"\($0.2)\">\($0.2)</a>" }
        t = t.replacing(/\*\*(.+?)\*\*|__(.+?)__/) { "<strong>\($0.1 ?? $0.2 ?? "")</strong>" }
        t = em.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "<em>$1$2</em>")
        t = t.replacing(/~~(.+?)~~/) { "<del>\($0.1)</del>" }
        return t.replacing(/\u{0}(\d+)\u{0}/) { codes[Int($0.1)!] }
    }

    /// 앱 테마(Anura 다크)에 맞춘 전체 문서. 폰트는 번들 파일을 직접 지정 (WebKit 은 별도 프로세스라 앱 등록 폰트를 못 봄)
    static func page(_ src: String, base: URL) -> String {
        let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts").absoluteString ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><base href="\(base.absoluteString)">
        <style>
        @font-face { font-family: Inter; src: url('\(fonts)Inter.ttf'); font-weight: 100 900; }
        @font-face { font-family: 'Source Code Pro'; src: url('\(fonts)SourceCodePro.ttf'); font-weight: 200 900; }
        :root { color-scheme: dark; }
        body { background: #1f1f1f; color: #e5e5e5; font: 15px/1.7 Inter, 'Apple SD Gothic Neo', sans-serif;
               max-width: 820px; margin: 0 auto; padding: 28px 36px 80px; -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4, h5, h6 { color: #f2f2f2; line-height: 1.3; margin: 1.6em 0 .6em; font-weight: 650; }
        h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid #3a3a3a; }
        h2 { font-size: 1.45em; padding-bottom: .25em; border-bottom: 1px solid #333; }
        h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; color: #c8c8c8; }
        body > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: #72e3ad; text-decoration: none; border-bottom: 1px solid rgba(114,227,173,.35); }
        strong { color: #fff; } del { color: #888; }
        code { font: .88em 'Source Code Pro', monospace; background: #2c2c2c; border: 1px solid #383838;
               border-radius: 5px; padding: .1em .35em; color: #e8c38f; }
        pre { background: linear-gradient(180deg, #282828, #242424); border: 1px solid #353535; border-radius: 10px;
              padding: 14px 16px; overflow-x: auto; }
        pre code { background: none; border: 0; padding: 0; color: #d8d8d8; font-size: .86em; line-height: 1.6; }
        blockquote { border-left: 3px solid #72e3ad; background: rgba(114,227,173,.06); margin-left: 0;
                     padding: .5em 1em; border-radius: 0 8px 8px 0; color: #bdbdbd; }
        blockquote > :last-child { margin-bottom: 0; }
        ul, ol { padding-left: 1.6em; } li { margin: .2em 0; } li::marker { color: #72e3ad; }
        li.task { list-style: none; margin-left: -1.3em; }
        li > ul, li > ol { margin: .2em 0 .2em; }
        input[type=checkbox] { accent-color: #72e3ad; margin-right: .4em; cursor: pointer; }
        .code { position: relative; margin: 0 0 1em; } .code pre { margin: 0; }
        .copy { position: absolute; top: 8px; right: 8px; font: 11px Inter, sans-serif; color: #bdbdbd; background: #333;
                border: 1px solid #444; border-radius: 6px; padding: 3px 9px; cursor: pointer; opacity: 0; transition: opacity .15s; }
        .code:hover .copy { opacity: 1; } .copy:hover { color: #72e3ad; border-color: #72e3ad; }
        html { scrollbar-width: thin; scrollbar-color: #4a4a4a transparent; }
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-thumb { background: #4a4a4a; border-radius: 4px; }
        ::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: transparent; }
        hr { border: 0; height: 1px; background: linear-gradient(90deg, transparent, #4a4a4a, transparent); margin: 2em 0; }
        table { border-collapse: separate; border-spacing: 0; border: 1px solid #3a3a3a; border-radius: 8px; overflow: hidden; }
        th, td { padding: 7px 13px; border-bottom: 1px solid #333; text-align: left; }
        th { background: #2a2a2a; font-weight: 600; } tr:last-child td { border-bottom: 0; }
        tbody tr:nth-child(even) { background: #232323; }
        img { max-width: 100%; border-radius: 8px; }
        ::selection { background: #2f4a3e; }
        </style></head><body>
        \(html(src))
        <script>
        // 복사 버튼 / 체크박스 → 앱 (클립보드 쓰기, 원문 [ ] ↔ [x] 변경)
        function copyCode(b) {
          webkit.messageHandlers.knt.postMessage({copy: b.parentNode.querySelector('code').textContent});
          b.textContent = '복사됨'; setTimeout(() => b.textContent = '복사', 1200);
        }
        document.querySelectorAll('input[data-line]').forEach(c =>
          c.addEventListener('change', () => webkit.messageHandlers.knt.postMessage({task: +c.dataset.line})));
        </script>
        </body></html>
        """
    }
}
