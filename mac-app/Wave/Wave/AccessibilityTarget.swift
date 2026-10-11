import AppKit
import ApplicationServices

@MainActor
enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    static func string(_ element: AXUIElement, _ name: String) -> String { value(element, name) as? String ?? "" }
    static func element(_ object: CFTypeRef?) -> AXUIElement? {
        guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &position),
              AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] { value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func descendants(_ root: AXUIElement, limit: Int = 700) -> [AXUIElement] {
        var pending = [root], result: [AXUIElement] = []
        while !pending.isEmpty && result.count < limit {
            let next = pending.removeFirst()
            result.append(next)
            pending.append(contentsOf: children(next))
        }
        return result
    }
    static func require(_ error: AXError, _ message: String) throws {
        guard error == .success else { throw ActionError.failed(message) }
    }
}

@MainActor
final class SelectedTarget {
    let id = UUID()
    let element: AXUIElement
    let context: PointedContext
    let pid: pid_t
    let appURL: URL?
    init(element: AXUIElement, context: PointedContext, pid: pid_t, appURL: URL?) {
        self.element = element; self.context = context; self.pid = pid; self.appURL = appURL
    }
    func validate() throws {
        guard NSRunningApplication(processIdentifier: pid) != nil,
              AX.frame(element) != nil else { throw ActionError.failed("That target is no longer available. Point at it again.") }
    }
}

@MainActor
enum TargetFinder {
    static func at(_ point: CGPoint) -> SelectedTarget? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<16 {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let app = NSRunningApplication(processIdentifier: pid)
            if pid == ProcessInfo.processInfo.processIdentifier { return nil }
            let role = AX.string(element, kAXRoleAttribute)
            let subrole = AX.string(element, kAXSubroleAttribute)
            if app?.bundleIdentifier == "com.apple.dock" {
                if subrole.contains("DockItem") || role.contains("DockItem") || role == "AXDockItem" || subrole == "AXApplicationDockItem" {
                    var title = AX.string(element, kAXTitleAttribute)
                    if title.isEmpty { title = AX.string(element, kAXDescriptionAttribute) }
                    if title.isEmpty { title = AX.string(element, kAXHelpAttribute) }
                    let url = AX.value(element, kAXURLAttribute) as? URL
                    guard !title.isEmpty, AX.frame(element) != nil else { return nil }
                    return SelectedTarget(element: element, context: PointedContext(app: title, kind: "dock_icon", title: title), pid: pid, appURL: url)
                }
            }
            if role == kAXWindowRole, AX.frame(element) != nil {
                // Ignore Desktop windows and background wallpaper windows
                if subrole == "AXDesktopWindow" || subrole == "AXDesktop" || role == "AXDesktop" { return nil }
                if app?.bundleIdentifier == "com.apple.finder" && (subrole != kAXStandardWindowSubrole || AX.string(element, kAXTitleAttribute).isEmpty) {
                    return nil
                }
                let name = app?.localizedName ?? app?.bundleURL?.deletingPathExtension().lastPathComponent ?? "App"
                let title = AX.string(element, kAXTitleAttribute)
                return SelectedTarget(element: element,
                                      context: PointedContext(app: name, kind: "window",
                                                              title: title.isEmpty ? nil : title),
                                      pid: pid, appURL: app?.bundleURL)
            }
            if let window = AX.element(AX.value(element, kAXWindowAttribute)), !CFEqual(window, element) {
                element = window
            } else if let parent = AX.element(AX.value(element, kAXParentAttribute)), !CFEqual(parent, element) {
                element = parent
            } else { return nil }
        }
        return nil
    }
}
