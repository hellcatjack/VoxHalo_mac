import AppKit

/// Remembers only interface-owned text; live transcripts and user input are excluded.
@MainActor final class NativeLocalizedViews {
    private let seen = NSHashTable<AnyObject>.weakObjects()
    private var updates: [() -> Void] = []

    func capture(_ view: NSView, excluding: [NSView] = []) {
        guard !excluding.contains(where: { $0 === view }) else { return }
        if !seen.contains(view) {
            seen.add(view)
            if let label = view.accessibilityLabel(), NativeLocalization.hasMessage(label) {
                updates.append { [weak view] in view?.setAccessibilityLabel(NativeLocalization.render(label)) }
            }
            if let tip = view.toolTip, NativeLocalization.hasMessage(tip) {
                updates.append { [weak view] in view?.toolTip = NativeLocalization.render(tip) }
            }
            if let field = view as? NSTextField {
                if !field.isEditable, NativeLocalization.hasMessage(field.stringValue) {
                    let original = field.stringValue
                    updates.append { [weak field] in field?.stringValue = NativeLocalization.render(original) }
                }
                if let original = field.placeholderString, NativeLocalization.hasMessage(original) {
                    updates.append { [weak field] in field?.placeholderString = NativeLocalization.render(original) }
                }
            } else if let button = view as? NSButton, !(button is NSPopUpButton), NativeLocalization.hasMessage(button.title) {
                let original = button.title
                updates.append { [weak button] in button?.title = NativeLocalization.render(original) }
            }
        }
        if let popup = view as? NSPopUpButton, let menu = popup.menu { capture(menu) }
        for child in view.subviews { capture(child, excluding: excluding) }
    }

    func capture(_ menu: NSMenu) {
        if !seen.contains(menu) {
            seen.add(menu)
            if NativeLocalization.hasMessage(menu.title) {
                let original = menu.title
                updates.append { [weak menu] in menu?.title = NativeLocalization.render(original) }
            }
        }
        for item in menu.items {
            if !seen.contains(item) {
                seen.add(item)
                if item.identifier?.rawValue != "literal", NativeLocalization.hasMessage(item.title) {
                    let original = item.title
                    updates.append { [weak item] in item?.title = NativeLocalization.render(original) }
                }
            }
            if let submenu = item.submenu { capture(submenu) }
        }
    }
    func apply() { for update in updates { update() } }
}
