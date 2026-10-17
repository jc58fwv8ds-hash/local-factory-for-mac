import AppKit
import ApplicationServices
import Foundation
import HarnessCore

/// Computer Use stage 1 on the real Mac (2026-10-18): the frontmost app other than Local Factory is read through the
/// accessibility API and numbered; the agent's action is done on the element with that number. Needs the user's
/// accessibility permission (granted by the user in System Settings; this app never changes it).
final class AccessibilityComputerUse: ComputerUseControlling, @unchecked Sendable {
    enum Failure: LocalizedError {
        case permission, noApplication, appNotFound(String), element(Int), action(String)
        var errorDescription: String? {
            switch self {
            case .permission: "画面操作には macOS のアクセシビリティの許可が必要です(システム設定でご自身で有効にしてください)"
            case .noApplication: "操作するアプリが前面にありません"
            case .appNotFound(let name): "「\(name)」というアプリが見つかりません"
            case .element(let id): "部品 [\(id)] は画面から消えています"
            case .action(let detail): detail
            }
        }
    }

    private let lock = NSLock()
    private var elementsByID: [Int: AXUIElement] = [:]
    private var target: NSRunningApplication?

    func observe() async throws -> ComputerUseObservation {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        let app = await MainActor.run { () -> NSRunningApplication? in
            let own = Bundle.main.bundleIdentifier
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != own { return front }
            return lock.withLock { target }
        }
        guard let app else { throw Failure.noApplication }
        lock.withLock { target = app }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let window = string(focusedWindow(root) ?? root, kAXTitleAttribute)
        var found: [(AXUIElement, ComputerUseElement)] = []
        var queue: [(AXUIElement, Int)] = [(focusedWindow(root) ?? root, 0)]
        var index = 0
        while index < queue.count, found.count < 150 {
            let (element, depth) = queue[index]; index += 1
            let role = string(element, kAXRoleAttribute)
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
                .map { string(element, $0) }.first { !$0.isEmpty } ?? ""
            let useful = ["AXButton", "AXTextField", "AXTextArea", "AXSecureTextField", "AXCheckBox", "AXRadioButton",
                          "AXPopUpButton", "AXMenuButton", "AXLink", "AXTab", "AXCell", "AXRow", "AXComboBox",
                          "AXSearchField", "AXStaticText"].contains(role)
            if useful, !(role == "AXStaticText" && label.isEmpty && string(element, kAXValueAttribute).isEmpty) {
                let value = role == "AXSecureTextField" ? "" : string(element, kAXValueAttribute)
                let id = found.count + 1
                found.append((element, .init(id: id, role: role, label: label.isEmpty ? value.prefix(60).description : label,
                                             value: role == "AXStaticText" ? "" : value, enabled: bool(element, kAXEnabledAttribute) ?? true)))
            }
            guard depth < 10 else { continue }
            queue.append(contentsOf: children(element).prefix(80).map { ($0, depth + 1) })
        }
        lock.withLock { elementsByID = Dictionary(uniqueKeysWithValues: found.map { ($0.1.id, $0.0) }) }
        return ComputerUseObservation(application: app.localizedName ?? "アプリ", window: window, elements: found.map(\.1))
    }

    func perform(_ action: ComputerUseAction, in observation: ComputerUseObservation) async throws -> String {
        let note = try await act(action)
        try? await Task.sleep(for: .milliseconds(800))   // let the app redraw before the next look
        return note
    }

    private func act(_ action: ComputerUseAction) async throws -> String {
        switch action {
        case .openApplication(let name):
            let url = try await MainActor.run { () throws -> URL in
                let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                               NSHomeDirectory() + "/Applications"]
                for folder in folders {
                    let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app")
                    if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                }
                throw Failure.appNotFound(name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            lock.withLock { target = app }
            try? await Task.sleep(for: .milliseconds(1200))
            return "開いた"
        case .press(let id):
            let element = try self.element(id)
            guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                throw Failure.action("[\(id)] は押せませんでした")
            }
            return "押した"
        case .type(let id, let text):
            let element = try self.element(id)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) != .success {
                typeCharacters(text)
            }
            return "入力した"
        case .menu(let path):
            guard let app = lock.withLock({ target }) else { throw Failure.noApplication }
            var current: AXUIElement? = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute)
            for (depth, title) in path.enumerated() {
                let items = children(current).flatMap { item in string(item, kAXRoleAttribute) == "AXMenu" ? children(item) : [item] }
                guard let item = items.first(where: { string($0, kAXTitleAttribute).localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
                    throw Failure.action("メニュー「\(title)」が見つかりません")
                }
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                if depth < path.count - 1 { try? await Task.sleep(for: .milliseconds(300)) }
                current = item
            }
            return "選んだ"
        case .key(let key):
            try press(key: key)
            return "押した"
        case .done, .askUser:
            return ""
        }
    }

    // MARK: helpers

    private func element(_ id: Int) throws -> AXUIElement {
        guard let element = lock.withLock({ elementsByID[id] }) else { throw Failure.element(id) }
        return element
    }

    private func attribute(_ element: AXUIElement?, _ name: String) -> AXUIElement? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func focusedWindow(_ app: AXUIElement) -> AXUIElement? { attribute(app, kAXFocusedWindowAttribute) }

    private func children(_ element: AXUIElement?) -> [AXUIElement] {
        guard let element else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func typeCharacters(_ text: String) {
        for scalar in text.utf16 {
            var unit = scalar
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "escape": 53, "space": 49, "delete": 51, "backspace": 51,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "f": 3, "z": 6, "c": 8, "v": 9, "w": 13, "r": 15, "t": 17, "q": 12, "l": 37, "n": 45,
    ]

    private func press(key: String) throws {
        let parts = key.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let last = parts.last, let code = Self.keyCodes[last] else { throw Failure.action("キー \(key) は使えません") }
        var flags: CGEventFlags = []
        if parts.contains("cmd") { flags.insert(.maskCommand) }
        if parts.contains("shift") { flags.insert(.maskShift) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
