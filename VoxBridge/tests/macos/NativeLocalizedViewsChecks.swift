import AppKit

@main
struct NativeLocalizedViewsChecks {
    @MainActor static func main() {
        let root = NSStackView()
        let button = NSButton(title: "开始传译", target: nil, action: nil)
        button.isEnabled = false
        let source = NSTextField(labelWithString: "启动服务")
        let terms = NSTextField(string: "中文 Gospel")
        terms.placeholderString = "ASR 提示词"
        let selection = NSPopUpButton()
        selection.addItem(withTitle: "英文"); selection.lastItem?.representedObject = "en"
        selection.addItem(withTitle: "中文"); selection.lastItem?.representedObject = "zh"
        selection.selectItem(at: 1)
        let device = NSPopUpButton()
        device.addItem(withTitle: "中文"); device.lastItem?.representedObject = "hardware-uid"
        device.lastItem?.identifier = NSUserInterfaceItemIdentifier("literal")
        for view in [button, source, terms, selection, device] { root.addArrangedSubview(view) }
        let bindings = NativeLocalizedViews()
        bindings.capture(root, excluding: [source])
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "复制", action: nil, keyEquivalent: "c")
        bindings.capture(menu)
        for locale in NativeLocalization.codes + ["en", "zh"] {
            UserDefaults.standard.setVolatileDomain(["interfaceLanguage": locale], forName: UserDefaults.argumentDomain)
            bindings.apply()
            assert(button.title == NativeLocalization.translate("开始传译", locale: locale))
            assert(!button.isEnabled)
            assert(source.stringValue == "启动服务")
            assert(terms.stringValue == "中文 Gospel")
            assert(terms.placeholderString == NativeLocalization.translate("ASR 提示词", locale: locale))
            assert(selection.selectedItem?.representedObject as? String == "zh")
            assert(selection.selectedItem?.title == NativeLocalization.translate("中文", locale: locale))
            assert(device.selectedItem?.title == "中文")
            assert(device.selectedItem?.representedObject as? String == "hardware-uid")
            assert(menu.title == NativeLocalization.translate("编辑", locale: locale))
            assert(menu.item(at: 0)?.title == NativeLocalization.translate("复制", locale: locale))
            assert(menu.item(at: 0)?.keyEquivalent == "c")
        }
        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        print("Native localized views: eight live switches preserve content, device codes and enabled state")
    }
}
