import AppKit
import ApplicationServices
import Foundation
import HarnessCore

struct MacAccessibleElement: Equatable, Sendable {
    let role: String
    let label: String
}

struct OpenedWebSearch: Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String?
}

enum MacComputerControllerError: LocalizedError {
    case accessibilityPermissionRequired
    case applicationNotRunning(String)
    case elementNotFound(String)
    case actionUnavailable(String)
    case searchUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "画面操作にはmacOSのアクセシビリティ許可が必要です。設定はユーザー自身が有効にしてください。"
        case let .applicationNotRunning(name):
            "「\(name)」が起動していません。先にアプリを開いてください。"
        case let .elementNotFound(label):
            "画面に「\(label)」という操作対象が見つかりませんでした。"
        case let .actionUnavailable(label):
            "「\(label)」は現在押せる状態ではありません。"
        case .searchUnavailable:
            "検索用のブラウザを開けませんでした。"
        }
    }
}

@MainActor
final class MacComputerController {
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func openAccessibilitySettings() {
        // Asking first puts this app in the Accessibility list and shows macOS's own dialog with a button to the setting
        // (2026-10-18: without it the app was not in the list to switch on). The user switches it on; nothing here does.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openWebSearch(_ query: String) throws -> OpenedWebSearch {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            throw MacComputerControllerError.searchUnavailable
        }
        let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        guard NSWorkspace.shared.open(url) else {
            throw MacComputerControllerError.searchUnavailable
        }
        let bundle = applicationURL.flatMap(Bundle.init(url:))
        let applicationName = applicationURL?
            .deletingPathExtension()
            .lastPathComponent ?? "Safari"
        return OpenedWebSearch(
            applicationName: applicationName,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }

    func readPublicSearchResults(
        from search: OpenedWebSearch
    ) throws -> [PublicWebSearchResult] {
        guard hasAccessibilityPermission else {
            throw MacComputerControllerError.accessibilityPermissionRequired
        }
        let application = try runningApplication(
            named: search.bundleIdentifier ?? search.applicationName
        )
        let root = AXUIElementCreateApplication(application.processIdentifier)
        let candidates: [PublicWebSearchResult] = elements(in: root).compactMap { element in
            let role = stringValue(element, attribute: kAXRoleAttribute as CFString)
            guard role == "AXLink" else { return nil }
            let title = snapshot(for: element).label
            let urlString = urlValue(element, attribute: kAXURLAttribute as CFString)
            guard !title.isEmpty, !urlString.isEmpty else { return nil }
            return PublicWebSearchResult(title: title, urlString: urlString)
        }
        return PublicWebSearchResultPolicy.filtered(candidates)
    }

    func inspect(application name: String) throws -> [MacAccessibleElement] {
        let application = try runningApplication(named: name)
        guard hasAccessibilityPermission else {
            throw MacComputerControllerError.accessibilityPermissionRequired
        }
        return elements(in: AXUIElementCreateApplication(application.processIdentifier))
            .prefix(80)
            .map { snapshot(for: $0) }
            .filter { !$0.label.isEmpty }
    }

    func pressButton(application name: String, label: String) throws {
        let application = try runningApplication(named: name)
        guard hasAccessibilityPermission else {
            throw MacComputerControllerError.accessibilityPermissionRequired
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = elements(in: root).first(where: {
            snapshot(for: $0).label.localizedCaseInsensitiveCompare(label) == .orderedSame
        }) else {
            throw MacComputerControllerError.elementNotFound(label)
        }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let values = actions as? [String],
              values.contains(kAXPressAction as String) else {
            throw MacComputerControllerError.actionUnavailable(label)
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw MacComputerControllerError.actionUnavailable(label)
        }
    }

    private func runningApplication(named name: String) throws -> NSRunningApplication {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
                || $0.localizedName?.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
        }) else {
            throw MacComputerControllerError.applicationNotRunning(cleaned)
        }
        return match
    }

    private func elements(in root: AXUIElement) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var result: [AXUIElement] = []
        var index = 0
        while index < queue.count, result.count < 320 {
            let (element, depth) = queue[index]
            index += 1
            result.append(element)
            guard depth < 6 else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &value
            ) == .success,
            let children = value as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.prefix(100).map { ($0, depth + 1) })
        }
        return result
    }

    private func snapshot(for element: AXUIElement) -> MacAccessibleElement {
        let role = stringValue(element, attribute: kAXRoleAttribute as CFString)
        let labels = [
            stringValue(element, attribute: kAXTitleAttribute as CFString),
            stringValue(element, attribute: kAXDescriptionAttribute as CFString),
            stringValue(element, attribute: kAXHelpAttribute as CFString),
            stringValue(element, attribute: kAXIdentifierAttribute as CFString)
        ]
        return MacAccessibleElement(
            role: role,
            label: labels.first(where: { !$0.isEmpty }) ?? ""
        )
    }

    private func stringValue(_ element: AXUIElement, attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func urlValue(_ element: AXUIElement, attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return ""
        }
        if let url = value as? URL { return url.absoluteString }
        return value as? String ?? ""
    }
}
