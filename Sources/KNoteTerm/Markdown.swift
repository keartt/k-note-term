import Foundation

/// 미리보기용 최소 마크다운 → HTML (GFM 자주 쓰는 것만: 제목, 목록/체크박스, 인용, 코드블록, 표, 구분선, 인라인)
enum Markdown {
    static func html(_ src: String) -> String {
        var out = "", para: [String] = [], list: String? = nil
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushPara() { if !para.isEmpty { out += "<p>\(para.map(inline).joined(separator: "<br>"))</p>\n"; para = [] } }
        func closeList() { if let l = list { out += "</\(l)>\n"; list = nil } }
        func flush() { flushPara(); closeList() }
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
                let fence = String(t.prefix(3)), lang = esc(String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                out += "<pre><code class=\"lang-\(lang)\">\(esc(code.joined(separator: "\n")))</code></pre>\n"
            } else if t.isEmpty {
                flush()
            } else if let m = t.firstMatch(of: /^(#{1,6})\s+(.*?)\s*#*$/) {
                flush()
                out += "<h\(m.1.count)>\(inline(String(m.2)))</h\(m.1.count)>\n"
            } else if t.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
                flush(); out += "<hr>\n"
            } else if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var s = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if s.hasPrefix(" ") { s = s.dropFirst() }
                    q.append(String(s)); i += 1
                }
                out += "<blockquote>\(html(q.joined(separator: "\n")))</blockquote>\n"
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
            } else if let m = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flushPara()
                let tag = m.2.first!.isNumber ? "ol" : "ul"
                if list != tag { closeList(); out += "<\(tag)>\n"; list = tag }
                var body = String(m.3), cls = ""
                if let c = body.firstMatch(of: /^\[([ xX])\]\s+(.*)$/) {
                    cls = " class=\"task\""
                    body = "<input type=\"checkbox\" disabled\(c.1 == " " ? "" : " checked")> " + inline(String(c.2))
                } else { body = inline(body) }
                let indent = min(m.1.count / 2, 4)
                out += "<li\(cls)\(indent > 0 ? " style=\"margin-left:\(Double(indent) * 1.4)em\"" : "")>\(body)</li>\n"
            } else {
                closeList()
                para.append(t)
            }
            i += 1
        }
        flush()
        return out
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
        input[type=checkbox] { accent-color: #72e3ad; margin-right: .4em; }
        hr { border: 0; height: 1px; background: linear-gradient(90deg, transparent, #4a4a4a, transparent); margin: 2em 0; }
        table { border-collapse: separate; border-spacing: 0; border: 1px solid #3a3a3a; border-radius: 8px; overflow: hidden; }
        th, td { padding: 7px 13px; border-bottom: 1px solid #333; text-align: left; }
        th { background: #2a2a2a; font-weight: 600; } tr:last-child td { border-bottom: 0; }
        tbody tr:nth-child(even) { background: #232323; }
        img { max-width: 100%; border-radius: 8px; }
        ::selection { background: #2f4a3e; }
        </style></head><body>
        \(html(src))
        </body></html>
        """
    }
}
