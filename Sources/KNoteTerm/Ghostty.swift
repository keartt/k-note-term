import AppKit
import GhosttyKit

/// libghostty 앱 런타임 (프로세스당 하나). Ghostty 앱 설치 없이 vendor/ghostty 소스로 빌드한 GhosttyKit 사용.
/// 키/IME/마우스/클립보드 처리는 ghostty/macos/Sources/Ghostty 의 SurfaceView_AppKit.swift 를 최소한으로 옮김.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    private(set) var app: ghostty_app_t?

    /// 앱 테마(Anura)에 맞춘 기본값 + 사용자가 쓰던 iTerm 키 습관. ~/.config/ghostty/config 가 있으면 그게 우선.
    /// 글꼴: D2Coding (앱에 포함) — 한글 폭이 영문의 정확히 2배라 띄엄띄엄 보이지 않음.
    /// term: xterm-ghostty 는 ssh 원격 서버에 정의가 없어 Ctrl+L·vim·less 가 깨짐 → 어디에나 있는 xterm-256color.
    /// D2Coding 의 | 는 가운데가 끊긴 모양이라 그 글자만 Source Code Pro 의 일자 막대로 대체.
    static let defaultConfig = """
    font-family = D2Coding
    font-codepoint-map = U+007C=Source Code Pro
    font-size = 14
    background = 1f1f1f
    foreground = e5e5e5
    cursor-color = 72e3ad
    cursor-style = bar
    cursor-style-blink = false
    selection-background = 2f4a3e
    window-padding-x = 8
    window-padding-y = 4
    window-padding-balance = true
    confirm-close-surface = false
    macos-option-as-alt = false
    shell-integration-features = no-cursor
    term = xterm-256color
    keybind = super+left=text:\\x01
    keybind = super+right=text:\\x05
    keybind = super+backspace=text:\\x15
    keybind = alt+left=esc:b
    keybind = alt+right=esc:f
    keybind = alt+backspace=text:\\x17

    """

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else { return }
        let file = AppState.file.deletingLastPathComponent().appendingPathComponent("ghostty.conf")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.defaultConfig.write(to: file, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, file.path)
        ghostty_config_load_default_files(config) // 사용자 Ghostty 설정이 있으면 덮어씀
        ghostty_config_finalize(config)

        var rt = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { GhosttyRuntime.shared.tick() } },
            action_cb: { _, target, action in GhosttyRuntime.handle(target, action) },
            read_clipboard_cb: { ud, _, state, mimes, count, _ in GhosttyRuntime.readClipboard(ud, state, mimes, count) },
            confirm_read_clipboard_cb: { ud, _, state, _ in
                // OSC 52 읽기 등 확인이 필요한 요청은 거부 (보안상 안전한 기본값)
                if let v = GhosttyTerm.from(ud), let s = v.surface { ghostty_surface_deny_clipboard_request(s, state) }
            },
            write_clipboard_cb: { _, loc, content, len, _ in
                guard loc == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
                for i in 0..<len where String(cString: content[i].mime) == "text/plain" {
                    let s = String(decoding: UnsafeRawBufferPointer(start: content[i].data, count: content[i].len), as: UTF8.self)
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(s, forType: .string)
                }
            },
            close_surface_cb: { ud, _ in
                let v = GhosttyTerm.from(ud)
                DispatchQueue.main.async { v?.onExit?() }
            }
        )
        app = ghostty_app_new(&rt, config)
        if let app { ghostty_app_set_focus(app, NSApp.isActive) }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, false) }
        }
    }

    func tick() { if let app { ghostty_app_tick(app) } }

    private static func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface,
              let v = GhosttyTerm.from(ghostty_surface_userdata(s)) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let t = action.action.set_title.title.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { v.title = t; v.onTitle?() }
            return true
        case GHOSTTY_ACTION_PWD:
            let p = action.action.pwd.pwd.map { String(cString: $0) }
            DispatchQueue.main.async { v.pwd = p }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let c: NSCursor = action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam
                : action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_POINTER ? .pointingHand : .arrow
            DispatchQueue.main.async { v.cursor = c; v.window?.invalidateCursorRects(for: v) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            if let p = u.url, let url = URL(string: String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self)) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return true
        default:
            return false
        }
    }

    /// 붙여넣기: text/plain 만 지원
    private static func readClipboard(_ ud: UnsafeMutableRawPointer?, _ state: UnsafeMutableRawPointer?,
                                      _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> ghostty_clipboard_read_result_e {
        guard let v = GhosttyTerm.from(ud), let surface = v.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let wantsText = (0..<count).contains { i in mimes?[i].map { String(cString: $0) == "text/plain" } ?? false }
        guard wantsText, let str = NSPasteboard.general.string(forType: .string) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        "text/plain".withCString { mime in
            let bytes = Array(str.utf8)
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(bytes.count, 1)) { data in
                    var content = ghostty_clipboard_content_s(mime: mime, data: data, len: bytes.count)
                    withUnsafePointer(to: &content) { cp in
                        var done = ghostty_clipboard_complete_s(contents: cp, contents_len: 1, available: nil, available_len: 0,
                                                                confirmed: false, remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &done, state)
                    }
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }
}

/// 터미널 패널 하나 = Ghostty surface 하나 (로그인 셸)
final class GhosttyTerm: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    var onExit: (() -> Void)?
    var onTitle: (() -> Void)?
    var title = ""
    var pwd: String?
    var cursor: NSCursor = .iBeam
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    static func from(_ ud: UnsafeMutableRawPointer?) -> GhosttyTerm? {
        ud.map { Unmanaged<GhosttyTerm>.fromOpaque($0).takeUnretainedValue() }
    }

    /// inherit: 새 탭/분할은 현재 패널의 작업 폴더·글자 크기를 이어받음. cwd: 지정 폴더에서 시작
    init(inherit: GhosttyTerm? = nil, split: Bool = false, cwd: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        wantsLayer = true
        guard let app = GhosttyRuntime.shared.app else { return }
        var cfg = inherit?.surface.map { ghostty_surface_inherited_config($0, split ? GHOSTTY_SURFACE_CONTEXT_SPLIT : GHOSTTY_SURFACE_CONTEXT_TAB) }
            ?? ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let dir = cwd ?? (inherit == nil ? FileManager.default.homeDirectoryForCurrentUser.path : nil)
        if let dir {
            surface = dir.withCString { p in cfg.working_directory = p; return ghostty_surface_new(app, &cfg) }
        } else {
            surface = ghostty_surface_new(app, &cfg)
        }
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let surface { ghostty_surface_free(surface) } }

    /// 사용자가 닫을 때: 종료 콜백 없이 셸 종료
    func kill() {
        onExit = nil
        if let s = surface { surface = nil; ghostty_surface_free(s) }
    }

    func action(_ a: String) { if let surface { _ = ghostty_surface_binding_action(surface, a, UInt(a.utf8.count)) } }
    func clear() { action("clear_screen") }
    var processExited: Bool { surface.map { ghostty_surface_process_exited($0) } ?? true }

    /// 화면에 보이는 글자 (자가 점검용)
    var visibleText: String {
        guard let surface else { return "" }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return "" }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                                          x: UInt32(size.columns - 1), y: UInt32(size.rows - 1)),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return text.text.map { String(cString: $0) } ?? ""
    }

    // MARK: 크기 / 배율 / 포커스

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { layer?.contentsScale = window.backingScaleFactor }
        updateSize()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSize()
    }
    private func updateSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(NSRect(origin: .zero, size: frame.size))
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
        if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // MARK: 마우스

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }
    private func button(_ state: ghostty_input_mouse_state_e, _ b: ghostty_input_mouse_button_e, _ e: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, b, mods(e.modifierFlags))
    }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        _ = button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, e)
    }
    override func mouseUp(with e: NSEvent) { _ = button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, e) }
    override func rightMouseDown(with e: NSEvent) { if !button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, e) { super.rightMouseDown(with: e) } }
    override func rightMouseUp(with e: NSEvent) { if !button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, e) { super.rightMouseUp(with: e) } }
    override func otherMouseDown(with e: NSEvent) { _ = button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, e) }
    override func otherMouseUp(with e: NSEvent) { _ = button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, e) }
    override func mouseMoved(with e: NSEvent) {
        guard let surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, mods(e.modifierFlags))
    }
    override func mouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func otherMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseExited(with e: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, mods(e.modifierFlags))
    }
    override func scrollWheel(with e: NSEvent) {
        guard let surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        if e.hasPreciseScrollingDeltas { x *= 2; y *= 2 }
        let momentum: Int32 = switch e.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (e.hasPreciseScrollingDeltas ? 1 : 0) | (momentum << 1))
    }

    // MARK: 키보드 (한글 IME 포함 — Ghostty macOS 앱과 같은 흐름)

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // ⌘ 단축키는 앱 메뉴가 처리. 메뉴에 없는 ⌘ 키(⌘← 등)는 이후 keyDown 으로 와서 Ghostty 키바인딩 적용.
        guard e.type == .keyDown, window?.firstResponder === self, e.modifierFlags.contains(.control),
              !e.modifierFlags.contains(.command) else { return false }
        // C-/ 를 C-_ 로 (macOS 비프음 방지), C-Return 그대로 전달
        let eq: String
        switch e.charactersIgnoringModifiers {
        case "/": eq = "_"
        case "\r": eq = "\r"
        default: return false
        }
        if let ev = NSEvent.keyEvent(with: .keyDown, location: e.locationInWindow, modifierFlags: e.modifierFlags,
                                     timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                     characters: eq, charactersIgnoringModifiers: eq, isARepeat: e.isARepeat, keyCode: e.keyCode) {
            keyDown(with: ev)
        }
        return true
    }

    override func keyDown(with e: NSEvent) {
        guard surface != nil else { interpretKeyEvents([e]); return }
        let action = e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        interpretKeyEvents([e])
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        // IME 가 조합 중이던 글자를 확정한 경우: 확정 글자만 보내고, 방향키만 다시 전달
        if markedBefore, let list = keyTextAccumulator, !list.isEmpty {
            for t in list where !suppress(t, composing) { _ = commitText(action, t) }
            if [124, 125, 126].contains(e.keyCode) || (e.keyCode == 123 && !e.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])) {
                _ = key(action, e)
            }
            return
        }
        if let list = keyTextAccumulator, !list.isEmpty {
            for t in list where !suppress(t, composing) { _ = key(action, e, text: t) }
        } else {
            if suppress(e.characters, composing) { return }
            _ = key(action, e, text: ghosttyCharacters(e), composing: composing)
        }
    }

    override func keyUp(with e: NSEvent) { _ = key(GHOSTTY_ACTION_RELEASE, e) }

    override func flagsChanged(with e: NSEvent) {
        let bit: UInt32
        switch e.keyCode {
        case 0x39: bit = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: bit = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: bit = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: bit = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: bit = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        _ = key(mods(e.modifierFlags).rawValue & bit != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, e)
    }

    private func suppress(_ text: String?, _ composing: Bool) -> Bool {
        guard composing, let s = text?.unicodeScalars, s.count == 1, let v = s.first?.value else { return false }
        return v < 0x20
    }

    private func ghosttyCharacters(_ e: NSEvent) -> String? {
        guard let chars = e.characters else { return nil }
        if chars.count == 1, let v = chars.unicodeScalars.first?.value {
            if v < 0x20 { return e.characters(byApplyingModifiers: e.modifierFlags.subtracting(.control)) }
            if v >= 0xF700 && v <= 0xF8FF { return nil } // 기능키 PUA
        }
        return chars
    }

    private func key(_ action: ghostty_input_action_e, _ e: NSEvent, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(e.keyCode)
        k.mods = mods(e.modifierFlags)
        k.consumed_mods = mods(e.modifierFlags.subtracting([.control, .command]))
        k.composing = composing
        if e.type == .keyDown || e.type == .keyUp, let c = e.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            k.unshifted_codepoint = c.value
        }
        if let text, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
            return text.withCString { p in k.text = p; return ghostty_surface_key(surface, k) }
        }
        return ghostty_surface_key(surface, k)
    }

    private func commitText(_ action: ghostty_input_action_e, _ text: String) -> Bool {
        guard let surface else { return false }
        var k = ghostty_input_key_s()
        k.action = action
        return text.withCString { p in k.text = p; return ghostty_surface_key(surface, k) }
    }

    private func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = 0
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = f.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: 편집 메뉴 (⌘C / ⌘V / ⌘A)

    @objc func copy(_ sender: Any?) { action("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { action("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { action("select_all") }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString(string: (string as? NSAttributedString)?.string ?? (string as? String) ?? "")
        if keyTextAccumulator == nil { syncPreedit() }
    }
    func unmarkText() {
        if markedText.length > 0 { markedText = NSMutableAttributedString(); syncPreedit() }
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let r = convert(NSRect(x: x, y: frame.height - y, width: w, height: h), to: nil)
        return window?.convertToScreen(r) ?? r
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(chars); return }
        if !chars.isEmpty { _ = commitText(GHOSTTY_ACTION_PRESS, chars) }
    }
    override func doCommand(by selector: Selector) {} // 엔터·백스페이스 등은 ghostty 가 키 이벤트로 처리

    // MARK: 파일/폴더 드롭 → 이스케이프된 절대경로 입력

    private func urls(_ s: NSDraggingInfo) -> [URL] {
        s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { urls(s).isEmpty ? [] : .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let list = urls(s)
        guard !list.isEmpty, let surface else { return false }
        let text = dropText(list, shell: true)
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        window?.makeFirstResponder(self)
        return true
    }
}
