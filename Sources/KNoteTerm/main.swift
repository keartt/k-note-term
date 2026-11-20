import AppKit
import Carbon
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainController!
    private var pending: [URL] = []

    /// Dock 아이콘에 드롭 / "다음으로 열기" / open -a
    func application(_ app: NSApplication, open urls: [URL]) {
        if let main { main.importExternal(urls) } else { pending += urls }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        main = MainController()
        // 자가 점검은 창을 맨 뒤에 띄움 (화면·키보드 포커스를 뺏지 않음)
        if isSelfTest { main.window.orderBack(nil) } else { main.window.makeKeyAndOrderFront(nil) }
        main.restoreLayout()
        if !pending.isEmpty { main.importExternal(pending); pending = [] }
        if !isSelfTest { NSApp.activate(ignoringOtherApps: true) }
        // 타이머로 시작: 메인 큐 블록 안에서 돌리면 대기 중에 Ghostty wakeup(메인 큐) 이 처리되지 않음
        if isSelfTest { Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in MainActor.assumeIsolated { self.selfTest() } } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { main.persist() }
    func applicationWillResignActive(_ n: Notification) { main.persist() }
    func applicationDidBecomeActive(_ n: Notification) { main?.sidebar.refresh() }

    /// 메뉴 단축키와 같은 경로(nil-target sendAction)로 주요 동작을 실행해 확인
    private func selfTest() {
        let m = main!
        var target: AnyObject? = nil // nil = 실제 메뉴처럼 응답자 체인 사용
        func send(_ s: Selector) { NSApp.sendAction(s, to: target, from: nil) }
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  \(what)" : "  FAIL \(what)"); if !ok { failed = true } }
        var failed = false
        // 자가 점검은 절대 포커스를 가져오지 않음 (사용자가 다른 앱에서 치는 키가 테스트 터미널로 들어가는 것 방지).
        // 키 윈도우가 아니면 응답자 체인 대신 컨트롤러에 직접 전송.
        if !m.window.isKeyWindow { target = m }
        let sb = m.sidebarVisible
        if m.terminalVisible { send(#selector(MainController.toggleTerminal)) }

        // 앱을 연 뒤 처음 여는 터미널이 바로 동작하는지: 셸이 살아 있고 화면에 프롬프트가 찍혀야 함
        send(#selector(MainController.toggleTerminal))
        let tDeadline = Date().addingTimeInterval(6)
        while (m.terminal.activeTerm?.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && Date() < tDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        // 셸 시작 출력이 멈출 때까지(0.6초간 변화 없음) 기다린 뒤 입력
        var last = "", stableSince = Date()
        while Date() < tDeadline.addingTimeInterval(4) {
            let now = m.terminal.activeTerm?.visibleText ?? ""
            if now != last { last = now; stableSince = Date() } else if Date().timeIntervalSince(stableSince) > 0.6 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let firstTerm = m.terminal.activeTerm
        let shown = firstTerm?.visibleText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let s = firstTerm?.surface {
            let sz = ghostty_surface_size(s)
            let scale = m.window.backingScaleFactor, em = 14 * scale
            let ratio = Double(sz.cell_width_px) / em
            check(abs(ratio - 0.5) < 0.06, "터미널 글꼴 D2Coding (칸 폭 \(sz.cell_width_px)px = \(String(format: "%.2f", ratio))em, 한글 2칸 = 1em)")
        }
        check(firstTerm?.surface != nil && firstTerm?.processExited == false && !shown.isEmpty,
              "Ghostty 터미널 첫 실행에 바로 셸 출력 (\(shown.split(separator: "\n").last.map { String($0.prefix(40)) } ?? "없음"))")

        // 키 입력 경로: 실제 keyDown 이벤트로 타이핑 → 셸이 실행한 결과가 화면에 나와야 함
        if let t = firstTerm {
            func type(_ s: String) {
                for ch in s {
                    let str = String(ch), code: UInt16 = ch == "\r" ? 36 : 0
                    for kind in [NSEvent.EventType.keyDown, .keyUp] {
                        if let ev = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: m.window.windowNumber, context: nil, characters: str,
                                                     charactersIgnoringModifiers: str, isARepeat: false, keyCode: code) {
                            kind == .keyDown ? t.keyDown(with: ev) : t.keyUp(with: ev)
                        }
                    }
                }
            }
            // 한글 입력기가 켜져 있으면 영문 키가 한글로 조합되므로 영문 타이핑 점검은 건너뜀
            let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let srcID = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(src, kTISPropertyInputSourceID)).takeUnretainedValue() as String
            let asciiInput = !srcID.lowercased().contains("korean")
            if asciiInput { type("echo knt$((40+2))\r") } else { print("  (입력기 \(srcID) — 영문 키 타이핑 점검 건너뜀)") }
            t.insertText("echo 한글입력; : '|a|b|'\r", replacementRange: NSRange(location: NSNotFound, length: 0)) // IME 확정 글자 경로
            let until = Date().addingTimeInterval(4)
            while !((!asciiInput || t.visibleText.contains("knt42")) && t.visibleText.contains("한글입력\n")) && Date() < until {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            check(!asciiInput || t.visibleText.contains("knt42"), "터미널 키 입력 → 셸 실행 결과 (knt42) [\(t.visibleText.split(separator: "\n").suffix(4).joined(separator: " | "))]")
            check(t.visibleText.components(separatedBy: "한글입력").count >= 3, "터미널 한글 입력 (IME 확정 글자) [\(t.visibleText.split(separator: "\n").suffix(4).joined(separator: " | "))]")
        }
        send(#selector(MainController.toggleTerminal))

        send(#selector(MainController.toggleSidebar))
        check(m.sidebarVisible != sb, "⌘B 사이드바 토글")
        send(#selector(MainController.toggleTerminal))
        check(m.terminalVisible && m.terminalFocused, "⌘⇧T 터미널 열림 + 포커스")
        check(abs(m.editorHeight - m.splitHeight / 2) < 3, "터미널이 화면 1/2 (에디터 \(Int(m.editorHeight)) / 전체 \(Int(m.splitHeight)))")
        // ⌘⇧E 에디터 숨기기 → 터미널이 에디터 자리로, 터미널을 숨기면 에디터 다시 보임
        send(#selector(MainController.toggleEditor))
        let edHid = !m.editorVisible && m.terminalVisible && m.terminalFocused
        send(#selector(MainController.toggleEditor))
        check(edHid && m.editorVisible && m.terminalVisible && abs(m.editorHeight - m.splitHeight / 2) < 3, "⌘⇧E 에디터 숨기기/보이기")
        send(#selector(MainController.toggleEditor))
        send(#selector(MainController.toggleTerminal))
        check(m.editorVisible && !m.terminalVisible, "에디터 숨긴 채 터미널 닫기 → 에디터 다시 보임")
        send(#selector(MainController.toggleTerminal))
        // ⌘⇧F 집중 모드: 터미널 포커스면 터미널만 + 헤더 숨김, 다시 누르면 원래대로
        let layoutBefore = (m.sidebarVisible, m.editorVisible)
        send(#selector(MainController.toggleFocusMode))
        let fOn = m.focusModeOn && !m.headerVisible && !m.sidebarVisible && !m.editorVisible && m.terminalVisible
        send(#selector(MainController.toggleFocusMode))
        check(fOn && !m.focusModeOn && m.headerVisible && (m.sidebarVisible, m.editorVisible) == layoutBefore && m.terminalFocused,
              "⌘⇧F 집중 모드 (터미널만 · 헤더 숨김 → 복원)")
        let tabsBefore = m.terminal.tabCount
        send(#selector(MainController.newTab))
        check(m.terminal.tabCount == tabsBefore + 1, "터미널 포커스에서 ⌘T = 터미널 새 탭")
        send(#selector(MainController.splitVertical))
        check(m.terminal.paneCount == 2, "⌘D 세로 분할")
        send(#selector(MainController.splitHorizontal))
        check(m.terminal.paneCount == 3, "⌘⇧D 가로 분할")
        send(#selector(MainController.closeTab))
        check(m.terminal.paneCount == 2, "터미널 포커스에서 ⌘W = 패널 닫기")
        send(#selector(MainController.closeTab)); send(#selector(MainController.closeTab))
        check(m.terminal.tabCount == tabsBefore, "마지막 패널 닫으면 탭 닫힘")

        m.window.makeFirstResponder(m.window.contentView) // 메모 쪽으로 포커스
        let docsBefore = m.docs.count
        send(#selector(MainController.newTab))
        let name = m.docs.last?.url.lastPathComponent ?? ""
        check(m.docs.count == docsBefore + 1 && name.hasSuffix(".md") && Int((name as NSString).deletingPathExtension.dropFirst(2)) != nil, "메모 포커스에서 ⌘T = 새 메모 (\(name))")
        send(#selector(MainController.closeTab))
        check(m.docs.count == docsBefore, "⌘W 메모 탭 닫기")

        // 탭을 모두 닫으면 새 메모를 만들지 않고 + 버튼만
        let restoreURLs = m.docs.map(\.url)
        while !m.docs.isEmpty { m.closeCurrent() }
        check(m.docs.isEmpty && m.currentViewer == "empty", "탭 모두 닫으면 빈 화면 + 버튼만 (\(m.currentViewer))")
        m.newBtn.performClick(nil)
        check(m.docs.count == 1 && m.currentViewer == "text", "+ 버튼 = 새 메모")
        m.closeCurrent()
        restoreURLs.forEach { m.open($0, select: false) }

        // 마크다운 미리보기
        let mdURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knt-preview-\(getpid()).md")
        try? "# 제목\n\n- [x] 할일\n- 항목 *기울임*\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n**굵게** `a*b*c` <tag>\n\n```swift\nlet x = 1 < 2\n```\n".write(to: mdURL, atomically: true, encoding: .utf8)
        m.open(mdURL, preview: true)
        let ph = m.previewText
        check(m.currentViewer == "preview" && ph.contains("<h1>제목</h1>") && ph.contains("checked") && ph.contains("<table>")
              && ph.contains("<em>기울임</em>") && ph.contains("<strong>굵게</strong>") && ph.contains("<code>a*b*c</code>")
              && ph.contains("&lt;tag&gt;") && ph.contains("let x = 1 &lt; 2"), "md 미리보기 렌더")
        send(#selector(MainController.togglePreview))
        check(m.currentViewer == "text", "⌘⇧P 미리보기 → 편집")
        m.closeCurrent()
        m.sidebar.onOpen?(mdURL)
        check(m.currentViewer == "text", "탐색기에서 연 md = 항상 편집기로 시작 (\(m.currentViewer))")  // 이 탭은 아래에서 닫음
        let crHTML = Markdown.html("a\r\r```\n# dd\n```")
        check(crHTML.contains("<pre>") && !crHTML.contains("<h1>"), "미리보기: 단독 CR 줄바꿈도 코드블록 인식")

        // 기본 폴더 메모: 문법 바꾸면 확장자도 변경
        send(#selector(MainController.newNote))
        let memo = m.currentURL!
        m.debugSetSyntax("JSON")
        let asJSON = m.currentURL!
        m.debugSetSyntax("Markdown")
        check(asJSON.pathExtension == "json" && FileManager.default.fileExists(atPath: asJSON.path) == false
              && m.currentURL == memo && FileManager.default.fileExists(atPath: memo.path), "문법 변경 → 메모 확장자 변경 (\(asJSON.lastPathComponent) → \(m.currentURL?.lastPathComponent ?? ""))")
        m.closeCurrent()

        // 에디터 분할 (⌘\\): 탭 바 하나, 탭 클릭 = 활성 칸, ⌥클릭 = 다른 칸
        let sa = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knt-split-a-\(getpid()).txt")
        let sb2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knt-split-b-\(getpid()).txt")
        try? "aaa".write(to: sa, atomically: true, encoding: .utf8)
        try? "bbb".write(to: sb2, atomically: true, encoding: .utf8)
        m.open(sb2); m.open(sa)
        send(#selector(MainController.toggleEditorSplit))
        let same = m.paneDocNames
        check(m.isSplit && same == [sa.lastPathComponent, sa.lastPathComponent] && m.activePane == 1, "⌘\\ 분할 = 같은 파일 두 칸 (\(same))")
        m.open(sb2)
        check(m.paneDocNames == [sa.lastPathComponent, sb2.lastPathComponent] && m.paneTexts == ["aaa", "bbb"],
              "분할 중 탭 클릭 = 활성 칸에만 표시, 다른 칸 내용은 그대로 (\(m.paneTexts))")
        let titles = m.tabTitles
        check(titles.contains { $0.hasPrefix(sa.lastPathComponent) && $0.hasSuffix("◧") } && titles.contains { $0.hasPrefix(sb2.lastPathComponent) && $0.hasSuffix("◨") },
              "탭에 ◧/◨ 칸 표시")
        m.window.makeFirstResponder(m.editorText)
        let typedPane = m.activePane
        if let ia = m.docs.firstIndex(where: { $0.url == sa }) { m.openInOther(ia) }
        check(m.activePane != typedPane && m.paneDocNames[m.activePane] == sa.lastPathComponent, "⌥클릭(다른 쪽에 열기) = 반대 칸")
        let beforeMove = m.activePane   // 위에서 반대 칸(0 = 왼쪽)으로 옮겨 둔 상태
        send(#selector(MainController.focusNextArea))
        check(beforeMove == 0 && m.activePane == 1, "⌃⌘→ 왼쪽 칸 → 오른쪽 칸 (\(beforeMove) → \(m.activePane))")
        // 칸에 떠 있는 탭을 닫으면 그 칸은 다음 탭으로
        m.window.makeFirstResponder(m.editorText)
        if let ib = m.docs.firstIndex(where: { $0.url == sb2 }) { m.openInOther(ib) }
        if let ib = m.docs.firstIndex(where: { $0.url == sb2 }) { m.closeTabAt(ib) }
        check(m.isSplit && !m.paneDocNames.contains(sb2.lastPathComponent) && !m.paneDocNames.contains("-"), "분할 칸의 탭 닫기 → 다음 탭 (\(m.paneDocNames))")
        send(#selector(MainController.rotateEditorSplit))
        send(#selector(MainController.toggleEditorSplit))
        check(!m.isSplit && m.paneDocNames.count == 1, "⌘\\ 다시 = 합치기")
        if let ia = m.docs.firstIndex(where: { $0.url == sa }) { m.closeTabAt(ia) }
        try? FileManager.default.removeItem(at: sa); try? FileManager.default.removeItem(at: sb2)

        // ⌘⌫ / 줄번호
        m.window.makeFirstResponder(m.editorText)
        let ed = m.editorText
        ed.selectAll(nil); ed.insertText("abc\nxy", replacementRange: ed.selectedRange())
        ed.deleteToBeginningOfLine(nil)
        let afterOne = ed.string
        ed.deleteToBeginningOfLine(nil)
        check(afterOne == "abc\n" && ed.string == "abc", "⌘⌫ 두 번 = 줄 내용 → 빈 줄까지 삭제 (\(ed.string.debugDescription))")
        check(m.lineRulerWidth > 20, "에디터 줄번호 표시")
        m.closeCurrent()
        try? FileManager.default.removeItem(at: mdURL)

        m.newBtn.showHint()
        check(IconButton.hintShowing == m.newBtn.tip, "아이콘 버튼 호버 설명")
        m.newBtn.hideHint()

        // 투명 타이틀바 아래 헤더 탭이 실제로 클릭되는지 (hit test). 사용자 탭이 없으면 임시 탭으로
        let hitTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("knt-hit-\(getpid()).txt")
        let needTmp = m.docs.isEmpty
        if needTmp { try? "x".write(to: hitTmp, atomically: true, encoding: .utf8); m.open(hitTmp) }
        defer { try? FileManager.default.removeItem(at: hitTmp) }
        m.window.contentView?.layoutSubtreeIfNeeded()
        let bar = m.editorTabs
        let p = bar.convert(NSPoint(x: 20, y: bar.bounds.midY), to: nil)
        let hit = m.window.contentView?.superview?.hitTest(m.window.contentView!.superview!.convert(p, from: nil))
        check(hit?.isDescendant(of: bar) ?? false, "헤더 탭 클릭 가능 (hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil"), bar=\(bar.frame), tabs=\(m.docs.count))")
        if needTmp { m.closeCurrent() }

        // 사이드바 너비를 바꾼 뒤 레이아웃이 다시 돌아도 유지되는지
        if !m.sidebarVisible { send(#selector(MainController.toggleSidebar)) }
        m.debugSetSidebarWidth(280)
        m.debugRelayout()
        check(abs(m.sidebarWidth - 280) < 2, "사이드바 너비 유지 (\(m.sidebarWidth))")
        check(abs(m.tabsX - (280 + 1 + 12)) < 2, "메모 탭이 사이드바 오른쪽에 정렬 (x=\(m.tabsX))")
        send(#selector(MainController.toggleSidebar)); send(#selector(MainController.toggleSidebar))
        check(abs(m.sidebarWidth - 280) < 2, "사이드바 닫았다 열어도 너비 유지 (\(m.sidebarWidth))")
        m.debugSetSidebarWidth(5000)
        check(m.sidebarWidth <= m.window.frame.width * 0.30 + 1, "탐색기 너비 최대 30% (\(m.sidebarWidth) / \(m.window.frame.width))")
        m.debugSetSidebarWidth(280)
        // 탐색기 포커스에서 탭 단축키 → 폴더 탭
        let tmp = FileManager.default.temporaryDirectory
        m.sidebar.addRoot(tmp)
        let roots = m.sidebar.rootCount
        check(m.sidebarFocused && m.sidebar.selectedRoot == roots - 1, "폴더 추가 후 탐색기 포커스 + 새 폴더 탭 선택")
        send(#selector(MainController.prevTab))
        check(m.sidebar.selectedRoot == roots - 2, "탐색기 포커스에서 ⌘⇧[ = 이전 폴더 탭")
        send(#selector(MainController.nextTab))
        send(#selector(MainController.closeTab))
        check(m.sidebar.rootCount == roots - 1, "탐색기 포커스에서 ⌘W = 추가 폴더 제거")
        m.sidebar.focus()
        let docsBeforeT = m.docs.count
        send(#selector(MainController.newTab))
        check(m.docs.count == docsBeforeT + 1 && m.sidebar.rootCount == roots - 1, "탐색기 포커스에서도 ⌘T = 새 메모")
        m.closeCurrent()
        // 드롭 경로: NFD 한글 → NFC, 셸 이스케이프 유지
        let nfd = URL(fileURLWithPath: "/tmp/새 메모".decomposedStringWithCanonicalMapping)
        let dropped = dropText([nfd], shell: true)
        check(dropped == "/tmp/새\\ 메모 " && dropped.unicodeScalars.count == "/tmp/새\\ 메모 ".unicodeScalars.count, "드롭 경로 NFC + 이스케이프 (\(dropped))")

        // ⌘⌥→ 영역 순환 + 민트 테두리
        if !m.terminalVisible { send(#selector(MainController.toggleTerminal)) }
        m.sidebar.focus()
        var seq = [m.visibleRing]
        for _ in 0..<3 { send(#selector(MainController.focusNextArea)); seq.append(m.visibleRing) }
        check(seq == ["sidebar", "editor", "terminal", "sidebar"], "⌃⌘→ 탐색기→메모→터미널→탐색기, 테두리 하나만 (\(seq))")
        send(#selector(MainController.focusPrevArea))
        check(m.visibleRing == "terminal", "⌃⌘← 이전 영역")
        if m.terminalVisible { send(#selector(MainController.toggleTerminal)) }

        // PDF / 이미지를 메모 탭에서 열기 (읽기 전용, 닫아도 파일 삭제 안 됨)
        let tmpDir = FileManager.default.temporaryDirectory
        let pdfURL = tmpDir.appendingPathComponent("knt-test.pdf"), pngURL = tmpDir.appendingPathComponent("knt-test.png")
        let pv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)); pv.string = "pdf"
        try? pv.dataWithPDF(inside: pv.bounds).write(to: pdfURL)
        let img = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        try? NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: pngURL)
        let before = m.docs.count
        m.open(pdfURL); check(m.currentViewer == "pdf", "PDF 를 메모 탭에서 열기 (\(m.currentViewer))")
        m.open(pngURL); check(m.currentViewer == "image", "이미지를 메모 탭에서 열기 (\(m.currentViewer))")
        send(#selector(MainController.fontReset))
        let z0 = m.zoomText
        send(#selector(MainController.fontBigger))
        let z1 = m.zoomText
        m.zoomOut()
        check(z0 == "100%" && z1 == "125%" && m.zoomText == "100%", "이미지 탭 ⌘+ / − 버튼 확대 축소 + 배율 (\(z0) → \(z1) → \(m.zoomText))")
        m.open(pdfURL)
        let p0 = m.zoomText
        send(#selector(MainController.fontBigger))
        check(m.zoomText != p0 && m.zoomText.hasSuffix("%"), "PDF 탭 ⌘+ 확대 (\(p0) → \(m.zoomText))")
        send(#selector(MainController.fontReset))
        m.open(pngURL)
        send(#selector(MainController.focusNextArea)); send(#selector(MainController.focusPrevArea))
        m.window.makeFirstResponder(m.window.contentView)
        send(#selector(MainController.closeTab)); send(#selector(MainController.closeTab))
        check(m.docs.count == before && FileManager.default.fileExists(atPath: pdfURL.path), "미디어 탭 닫기 (파일은 유지)")

        // 외부 파일 가져오기 → 폴더가 탐색기 탭으로 추가 + 메모 탭에서 열림
        let extDir = tmpDir.appendingPathComponent("knt-ext-\(getpid())")
        try? FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let extFile = extDir.appendingPathComponent("외부.txt")
        try? "hello".write(to: extFile, atomically: true, encoding: .utf8)
        let rootsBefore = m.sidebar.rootCount
        m.importExternal([extFile])
        check(m.sidebar.rootCount == rootsBefore + 1 && m.sidebar.folders.last?.standardizedFileURL == extDir.standardizedFileURL
              && m.currentURL?.standardizedFileURL == extFile.standardizedFileURL, "외부 파일 → 탐색기 새 탭 + 메모 탭 열기")

        // 탐색기에서 ⌘⌫ 휴지통 → 열린 탭 닫힘 → ⌘Z 복구
        m.sidebar.reveal(extFile)
        m.sidebar.trashSelected()
        check(!FileManager.default.fileExists(atPath: extFile.path) && m.currentURL?.standardizedFileURL != extFile.standardizedFileURL, "탐색기 ⌘⌫ 휴지통 + 열린 탭 닫기")
        // 메뉴 ⌘Z 와 같은 경로: 첫 응답자(탐색기 트리)부터 응답자 체인으로 undo: 전달
        m.sidebar.focus()
        _ = m.window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        check(FileManager.default.fileExists(atPath: extFile.path), "탐색기 ⌘Z 삭제 되돌리기 (응답자 체인)")
        _ = m.window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        check(!FileManager.default.fileExists(atPath: extFile.path), "탐색기 ⌘⇧Z 다시 삭제")
        m.sidebar.undoFileOp()
        m.sidebar.removeCurrent()
        try? FileManager.default.removeItem(at: extDir)


        // 탐색기 UX: 새 메모 + 이름 변경 / 하위 폴더 파일 표시 / 터미널에서 열기
        let ux = tmpDir.appendingPathComponent("knt-ux-\(getpid())")
        let deep = ux.appendingPathComponent("sub/깊은파일.txt")
        try? FileManager.default.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "x".write(to: deep, atomically: true, encoding: .utf8)
        m.sidebar.addRoot(ux)
        m.open(deep)
        check(m.sidebar.selectedURL?.standardizedFileURL == deep.standardizedFileURL, "메모 탭 전환 시 탐색기에서 하위 폴더 파일 표시")
        m.sidebar.create(in: ux, folder: false)
        (m.window.firstResponder as? NSTextView)?.string = "이름바꿈.md"
        m.sidebar.focus() // 편집 종료 → 이름 변경
        check(FileManager.default.fileExists(atPath: ux.appendingPathComponent("이름바꿈.md").path)
              && !FileManager.default.fileExists(atPath: ux.appendingPathComponent("새 메모.md").path), "탐색기 새 메모 + 이름 변경")
        // 탐색기 ⌘C / ⌘V 파일 복사 → ⌘Z 되돌리기, 드래그 이동 → ⌘Z 되돌리기
        let fm = FileManager.default
        m.sidebar.reveal(deep)
        m.sidebar.copySelectedFiles()
        m.sidebar.reveal(ux.appendingPathComponent("이름바꿈.md"))
        m.sidebar.pasteFiles()
        let copied = ux.appendingPathComponent("깊은파일.txt")
        let pasteOK = fm.fileExists(atPath: copied.path) && m.sidebar.selectedURL?.standardizedFileURL == copied.standardizedFileURL
        m.sidebar.reveal(deep.deletingLastPathComponent())
        m.sidebar.pasteFiles()
        let dup = fm.fileExists(atPath: deep.deletingLastPathComponent().appendingPathComponent("깊은파일 2.txt").path)
        m.sidebar.undoFileOp(); m.sidebar.undoFileOp()
        check(pasteOK && dup && !fm.fileExists(atPath: copied.path) && fm.fileExists(atPath: deep.path), "탐색기 ⌘C/⌘V 파일 붙여넣기 (같은 이름은 \"이름 2\") + ⌘Z")
        m.open(deep)
        m.sidebar.transfer([deep], to: ux, move: true)
        let moved = fm.fileExists(atPath: copied.path) && !fm.fileExists(atPath: deep.path) && m.currentURL?.standardizedFileURL == copied.standardizedFileURL
        m.sidebar.transfer([deep.deletingLastPathComponent()], to: deep.deletingLastPathComponent(), move: true) // 자기 안으로 = 무시
        m.sidebar.undoFileOp()
        check(moved && fm.fileExists(atPath: deep.path) && m.currentURL?.standardizedFileURL == deep.standardizedFileURL, "탐색기 드래그 이동 → 열린 탭 경로 따라감 + ⌘Z")
        m.sidebar.onOpenTerminal?(ux)
        if let t = m.terminal.activeTerm {
            let pDeadline = Date().addingTimeInterval(6)
            while t.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Date() < pDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            t.insertText("pwd -P\r", replacementRange: NSRange(location: NSNotFound, length: 0))
            let real = ux.resolvingSymlinksInPath().path
            while !t.visibleText.contains(real) && Date() < pDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            check(t.visibleText.contains(real), "탐색기 '터미널에서 열기' → 그 폴더에서 셸 시작")
            check(t.pwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == real && !t.title.isEmpty,
                  "Ghostty 셸 통합: 작업 폴더·제목 보고 (pwd=\(t.pwd ?? "nil"), 제목=\(t.title))")
        }
        // 터미널 탭 별칭: 탭 이름 편집 → 확정
        func typeInEditor(_ s: String) {
            (m.window.firstResponder as? NSTextView)?.string = s
            m.window.makeFirstResponder(m.window.contentView) // 편집 종료 = 확정
        }
        let ti = m.terminal.tabCount - 1
        m.terminal.beginRename(ti)
        typeInEditor("서버")
        check(m.terminal.tabTitles[safe: ti] == "서버", "터미널 탭 별칭 지정 (\(m.terminal.tabTitles))")
        m.terminal.beginRename(ti)
        typeInEditor("")
        check(m.terminal.tabTitles[safe: ti] != "서버", "터미널 탭 별칭 비우면 자동 이름으로 (\(m.terminal.tabTitles[safe: ti] ?? ""))")
        m.terminal.closePane()
        if m.terminalVisible { send(#selector(MainController.toggleTerminal)) }

        // 탐색기 ⌥C = 선택 항목 경로 복사
        m.sidebar.reveal(deep)
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: m.window.windowNumber,
                                     context: nil, characters: "ç", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
            NSPasteboard.general.clearContents()
            m.sidebar.treeView.keyDown(with: ev)
        }
        check(NSPasteboard.general.string(forType: .string).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == deep.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping, "탐색기 ⌥C 경로 복사 (\(NSPasteboard.general.string(forType: .string) ?? "nil") sel=\(m.sidebar.selectedURL?.path ?? "nil"))")

        // 탐색기 ⌘↓ = 선택 파일 열기 (한 번 클릭은 선택만)
        m.sidebar.reveal(deep)
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function], timestamp: 0,
                                     windowNumber: m.window.windowNumber, context: nil, characters: "\u{F701}",
                                     charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) {
            m.window.makeFirstResponder(m.window.contentView)
            m.sidebar.treeView.keyDown(with: ev)
        }
        check(m.currentURL?.resolvingSymlinksInPath() == deep.resolvingSymlinksInPath(), "탐색기 ⌘↓ = 선택 파일 열기")

        // 메모 탭 이름 변경 = 파일 이름 변경 (확장자 유지)
        let tabFile = ux.appendingPathComponent("탭이름.md")
        try? "t".write(to: tabFile, atomically: true, encoding: .utf8)
        m.open(tabFile)
        if let i = m.docs.firstIndex(where: { $0.url == tabFile }) {
            m.editorTabs.beginEdit(i)
            m.focusArea(clicked: m.editorTabs)   // 탭 더블클릭의 클릭 포커스 처리가 편집칸을 닫으면 안 됨
            check((m.window.firstResponder as? NSTextView)?.string == "탭이름", "메모 탭 편집은 확장자 뺀 이름만")
            typeInEditor("바뀐탭")
        }
        let renamedFile = ux.appendingPathComponent("바뀐탭.md")
        check(FileManager.default.fileExists(atPath: renamedFile.path) && !FileManager.default.fileExists(atPath: tabFile.path)
              && m.currentURL?.lastPathComponent == "바뀐탭.md", "메모 탭 이름 변경 → 파일 이름 변경, 확장자 유지 (\(m.currentURL?.lastPathComponent ?? ""))")
        for i in m.docs.indices.reversed() where m.docs[i].url.path.hasPrefix(ux.path) { m.window.makeFirstResponder(m.window.contentView); _ = i; send(#selector(MainController.closeTab)) }
        // 밖에서 파일이 생기면 (FSEvents) 새로고침 없이 탐색기에 바로 나타남
        m.sidebar.selectRoot(m.sidebar.rootCount - 1)
        let outside = ux.appendingPathComponent("밖에서생김.txt")
        try? "x".write(to: outside, atomically: true, encoding: .utf8)
        let fsDeadline = Date().addingTimeInterval(4)
        func listed() -> Bool { (0..<m.sidebar.treeView.numberOfRows).contains { (m.sidebar.treeView.item(atRow: $0) as? FileNode)?.url.lastPathComponent == "밖에서생김.txt" } }
        while !listed() && Date() < fsDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        check(listed(), "외부 변경 즉시 탐색기 반영 (FSEvents)")
        try? "x".write(to: ux.appendingPathComponent(".숨김"), atomically: true, encoding: .utf8)
        m.sidebar.refresh()
        func hiddenListed() -> Bool { (0..<m.sidebar.treeView.numberOfRows).contains { (m.sidebar.treeView.item(atRow: $0) as? FileNode)?.url.lastPathComponent == ".숨김" } }
        let wasShown = FileNode.showHidden
        if !wasShown { m.sidebar.toggleHidden() }
        let hiddenShown = hiddenListed()
        m.sidebar.toggleHidden()
        let hid = !hiddenListed()
        m.sidebar.toggleHidden()
        if !wasShown { m.sidebar.toggleHidden() }
        check(hiddenShown && hid, "눈 아이콘 = 숨김 파일 보기/숨기기")
        m.sidebar.selectRoot(m.sidebar.rootCount - 1); m.sidebar.removeCurrent()
        try? FileManager.default.removeItem(at: ux)

        // 탐색기 아이콘 / 경로 라벨 클릭 복사 / 더블클릭·⌘↓ 열기
        check(FileIcons.name(for: URL(fileURLWithPath: "a.md"), isDir: false, open: false) == "markdown"
              && FileIcons.image(for: URL(fileURLWithPath: "a.swift"), isDir: false, open: false)?.size == NSSize(width: 16, height: 16),
              "탐색기 Material 아이콘 (확장자별 SVG 로드)")
        NSPasteboard.general.clearContents()
        m.sidebar.clickPathLabel()
        check(NSPasteboard.general.string(forType: .string) == m.sidebar.folders[m.sidebar.selectedRoot].path.precomposedStringWithCanonicalMapping,
              "탐색기 경로 라벨 클릭 = 경로 복사")
        check(m.sidebar.copyIconTint == Theme.accent, "경로 복사 → 복사 아이콘 초록")

        // 영역 안 아무 곳 클릭 = 그 영역 포커스 (탭 줄, 빈 곳 등)
        m.focusArea(clicked: m.sidebar)
        let sideOK = m.sidebarFocused
        m.focusArea(clicked: m.editorTabs)
        check(sideOK && !m.sidebarFocused && !m.terminalFocused, "영역 클릭 포커스 (탐색기 빈 곳 → 탐색기, 에디터 탭 줄 → 에디터)")

        check(Theme.ui(12).familyName == "Inter" && Theme.mono(12).familyName == "Source Code Pro", "번들 폰트 로드 (Inter / Source Code Pro)")

        // 화면 녹화 권한 없이 창 내용을 PNG 로 렌더 (디자인 확인용)
        if let out = ProcessInfo.processInfo.environment["KNT_SNAPSHOT"] {
            m.open(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../../../../Sources/KNoteTerm/Theme.swift").standardizedFileURL)
            if !m.sidebarVisible { send(#selector(MainController.toggleSidebar)) }
            if !m.terminalVisible { send(#selector(MainController.toggleTerminal)) }
            send(#selector(MainController.splitVertical))
            // 에디터 분할 모습: 왼쪽 Theme.swift, 오른쪽 README.md, 포커스 = 오른쪽 칸
            m.window.makeFirstResponder(m.editorText)
            send(#selector(MainController.toggleEditorSplit))
            m.open(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../../../../README.md").standardizedFileURL)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let v = m.window.contentView!.superview!
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            send(#selector(MainController.toggleEditorSplit))
            send(#selector(MainController.closeTab))
            send(#selector(MainController.toggleSidebar))
            send(#selector(MainController.toggleTerminal))
        }

        // 원상복구
        send(#selector(MainController.toggleSidebar))
        send(#selector(MainController.toggleTerminal))
        print(failed ? "SELFTEST FAIL" : "SELFTEST OK")
        exit(failed ? 1 : 0)
    }

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(); host.submenu = m
            bar.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        let find = #selector(NSTextView.performFindPanelAction(_:))
        func arrow(_ k: Int) -> String { String(UnicodeScalar(UInt32(k))!) }
        menu("KNoteTerm", [
            item("KNoteTerm 가리기", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("KNoteTerm 종료", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("파일", [
            item("새 탭 (메모/터미널)", #selector(MainController.newTab), "t"),
            item("새 메모", #selector(MainController.newNote), "n"),
            item("열기…", #selector(MainController.openPanel), "o"),
            .separator(),
            item("폴더 추가…", #selector(MainController.addFolder), "o", [.command, .shift]),
            item("기본 폴더 변경…", #selector(MainController.changeNotesDir)),
            .separator(),
            item("저장", #selector(MainController.saveNow), "s"),
            item("닫기 (탭/패널)", #selector(MainController.closeTab), "w"),
        ])
        menu("편집", [
            item("실행 취소", Selector(("undo:")), "z"),
            item("실행 복귀", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("오려두기", #selector(NSText.cut(_:)), "x"),
            item("복사하기", #selector(NSText.copy(_:)), "c"),
            item("붙여넣기", #selector(NSText.paste(_:)), "v"),
            item("전체 선택", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("찾기…", find, "f", tag: 1),
            item("찾기 및 바꾸기…", find, "f", [.command, .option], tag: 12),
            item("다음 찾기", find, "g", tag: 2),
            item("이전 찾기", find, "g", [.command, .shift], tag: 3),
            item("선택 항목으로 찾기", find, "e", tag: 7),
        ])
        menu("보기", [
            item("사이드바", #selector(MainController.toggleSidebar), "b"),
            item("터미널", #selector(MainController.toggleTerminal), "t", [.command, .shift]),
            item("에디터", #selector(MainController.toggleEditor), "e", [.command, .shift]),
            item("마크다운 미리보기", #selector(MainController.togglePreview), "p", [.command, .shift]),
            item("에디터 분할 / 합치기", #selector(MainController.toggleEditorSplit), "\\"),
            item("에디터 분할 방향 바꾸기", #selector(MainController.rotateEditorSplit), "\\", [.command, .option]),
            item("집중 모드 (전체 화면 · 헤더 숨김)", #selector(MainController.toggleFocusMode), "f", [.command, .shift]),
            .separator(),
            item("글자 크게", #selector(MainController.fontBigger), "="),
            item("글자 작게", #selector(MainController.fontSmaller), "-"),
            item("기본 크기", #selector(MainController.fontReset), "0"),
            .separator(),
            item("다음 탭", #selector(MainController.nextTab), "]", [.command, .shift]),
            item("이전 탭", #selector(MainController.prevTab), "[", [.command, .shift]),
            .separator(),
            // 영역 이동: ⌃⌘→ / ⌃⌘↓ 다음, ⌃⌘← / ⌃⌘↑ 이전
            item("다음 영역 (탐색기→메모→터미널)", #selector(MainController.focusNextArea), arrow(NSRightArrowFunctionKey), [.command, .control]),
            item("다음 영역", #selector(MainController.focusNextArea), arrow(NSDownArrowFunctionKey), [.command, .control]),
            item("이전 영역", #selector(MainController.focusPrevArea), arrow(NSLeftArrowFunctionKey), [.command, .control]),
            item("이전 영역", #selector(MainController.focusPrevArea), arrow(NSUpArrowFunctionKey), [.command, .control]),
        ] + (1...9).map { item("탭 \($0)", #selector(MainController.selectTabN(_:)), "\($0)", tag: $0) })
        menu("터미널", [
            item("세로 분할", #selector(MainController.splitVertical), "d"),
            item("가로 분할", #selector(MainController.splitHorizontal), "d", [.command, .shift]),
            item("다음 패널", #selector(MainController.nextPane), "]"),
            item("이전 패널", #selector(MainController.prevPane), "["),
            .separator(),
            item("화면 지우기", #selector(MainController.clearTerminal), "k"),
        ])
        menu("윈도우", [
            item("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        return bar
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
