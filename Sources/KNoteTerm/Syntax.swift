import AppKit

/// 정규식 기반 하이라이터. CotEditor 의 syntax 정의를 축소한 형태.
struct Syntax {
    let name: String
    let files: [String]                       // 확장자 또는 파일명
    var rules: [(NSRegularExpression, NSColor)] = []
    /// 주석(그룹1) / 문자열(그룹2) 을 한 정규식으로 — 왼쪽부터 먼저 시작한 쪽이 이김 ("http://" 가 주석 되는 문제 방지)
    var commentOrString: NSRegularExpression? = nil

    // CotEditor Anura (Dark)
    static let keyword = Theme.rgb(0x4D92AB), string = Theme.rgb(0x90AD65), comment = Theme.rgb(0x808080),
               number = Theme.rgb(0xA97DD1), attr = Theme.rgb(0xC76090)

    static func code(_ name: String, _ files: String, _ words: String, line: String?, block: Bool = true) -> Syntax {
        var c = [String]()
        if let line { c.append(NSRegularExpression.escapedPattern(for: line) + ".*$") }
        if block { c.append(#"/\*[\s\S]*?\*/"#) }
        let comment = c.isEmpty ? "(?!)" : c.joined(separator: "|")
        return Syntax(name: name, files: files.split(separator: " ").map(String.init), rules: [
            (rx(#"\b\d+(\.\d+)?\b"#), number),
            (rx(#"\b("# + words.split(separator: " ").joined(separator: "|") + #")\b"#), keyword),
        ], commentOrString: rx("(\(comment))|(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*')"))
    }

    static let all: [Syntax] = [
        Syntax(name: "Plain Text", files: []),
        Syntax(name: "Markdown", files: ["md", "markdown", "txt"], rules: [
            (rx(#"^#{1,6} .*$"#), keyword),
            (rx(#"^\s*([-*+]|\d+\.) "#), number),
            (rx(#"^>.*$"#), comment),
            (rx(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#), attr),
            (rx(#"\[[^\]\n]*\]\([^)\n]*\)"#), attr),
            (rx(#"`[^`\n]+`|^```[\s\S]*?^```"#), string),
        ]),
        code("Swift", "swift", "class struct enum protocol extension func var let if else guard return for in while repeat switch case default break continue import init deinit self Self super nil true false throws throw try catch async await private fileprivate internal public open static final override weak lazy some any where as is defer inout", line: "//"),
        code("JavaScript", "js jsx mjs cjs ts tsx", "var let const function return if else for while do switch case default break continue new delete typeof instanceof in of class extends super this null undefined true false import export from as async await try catch finally throw yield interface type enum implements public private protected readonly", line: "//"),
        code("Java", "java kt kts groovy gradle", "abstract boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public return short static super switch synchronized this throw throws transient try void volatile while null true false var val fun object when", line: "//"),
        code("Python", "py", "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield None True False self", line: "#", block: false),
        code("Shell", "sh bash zsh .zshrc .bashrc .zprofile .bash_profile .profile", "if then else elif fi for while until do done case esac in function return export local readonly source alias unset echo cd exit", line: "#", block: false),
        code("SQL", "sql", "SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX VIEW JOIN LEFT RIGHT INNER OUTER FULL ON AS GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT UNION ALL NULL IS IN LIKE BETWEEN CASE WHEN THEN ELSE END PRIMARY KEY FOREIGN REFERENCES DEFAULT WITH select from where and or not insert into values update set delete create table alter drop index view join left right inner outer full on as group by order having limit offset distinct union all null is in like between case when then else end primary key foreign references default with", line: "--"),
        code("Go", "go", "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false", line: "//"),
        code("C/C++", "c h cpp hpp cc m mm", "auto break case char const continue default do double else enum extern float for goto if int long register return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace template typename public private protected virtual new delete this nullptr true false include define", line: "//"),
        code("Rust", "rs", "as break const continue crate else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while async await dyn", line: "//"),
        Syntax(name: "JSON", files: ["json"], rules: [
            (rx(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#), number),
            (rx(#"\b(true|false|null)\b"#), keyword),
            (rx(#""(?:\\.|[^"\\\n])*""#), string),
            (rx(#""(?:\\.|[^"\\\n])*"(?=\s*:)"#), attr),
        ]),
        Syntax(name: "YAML", files: ["yml", "yaml"], rules: [
            (rx(#"\b\d+(\.\d+)?\b"#), number),
            (rx(#"\b(true|false|null|yes|no)\b"#), keyword),
            (rx(#"^\s*-?\s*[\w.\-"']+(?=\s*:)"#, .anchorsMatchLines), attr),
        ], commentOrString: rx(#"((?:^|\s)#.*$)|("(?:\\.|[^"\\\n])*"|'[^'\n]*')"#)),
        Syntax(name: "XML/HTML", files: ["xml", "html", "htm", "xhtml", "svg", "plist", "vue"], rules: [
            (rx(#"</?[\w:.\-]+|/?>"#), keyword),
            (rx(#"\b[\w:\-]+(?==)"#), attr),
        ], commentOrString: rx(#"(<!--[\s\S]*?-->)|("[^"]*"|'[^']*')"#)),
        Syntax(name: "CSS", files: ["css", "scss", "less"], rules: [
            (rx(#"-?\b\d+(\.\d+)?(px|em|rem|%|vh|vw|s|ms)?\b"#), number),
            (rx(#"#[0-9a-fA-F]{3,8}\b"#), number),
            (rx(#"[\w\-]+(?=\s*:[^;{]*[;}])"#), attr),
        ], commentOrString: rx(#"(/\*[\s\S]*?\*/)|("[^"\n]*"|'[^'\n]*')"#)),
        Syntax(name: "Properties", files: ["properties", "ini", "conf", "env", "toml", ".env"], rules: [
            (rx(#"^\s*[^#;=\s][^=:\n]*(?=[=:])"#), attr),
            (rx(#"^\s*\[.*\]\s*$"#), keyword),
        ], commentOrString: rx(#"(^\s*[#;].*$)|("[^"\n]*")"#)),
    ]

    static func named(_ n: String?) -> Syntax? { all.first { $0.name == n } }

    static func detect(_ url: URL) -> Syntax {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent
        return all.first { $0.files.contains(ext) || $0.files.contains(name) } ?? markdown // 기본 = 마크다운
    }

    static var markdown: Syntax { named("Markdown")! }

    func apply(to ts: NSTextStorage, base: [NSAttributedString.Key: Any]) {
        let full = NSRange(location: 0, length: ts.length), s = ts.string
        ts.beginEditing()
        ts.setAttributes(base, range: full)
        if ts.length < 3_000_000 { // 전체 재하이라이트, 수 MB 넘으면 생략. 큰 파일 필요하면 보이는 영역만 칠하기
            for (re, color) in rules {
                re.enumerateMatches(in: s, range: full) { m, _, _ in
                    if let r = m?.range, r.length > 0 { ts.addAttribute(.foregroundColor, value: color, range: r) }
                }
            }
            commentOrString?.enumerateMatches(in: s, range: full) { m, _, _ in
                guard let m, m.range.length > 0 else { return }
                let isComment = m.range(at: 1).location != NSNotFound
                ts.addAttribute(.foregroundColor, value: isComment ? Syntax.comment : Syntax.string, range: m.range)
            }
        }
        ts.endEditing()
    }
}

private func rx(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
    try! NSRegularExpression(pattern: p, options: o.union(.anchorsMatchLines))
}
