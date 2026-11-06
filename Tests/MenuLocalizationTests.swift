import AppKit
@main enum MenuTests {
    @MainActor static func main() {
        let root=NSMenu(title:"Menu")
        let item=NSMenuItem(title:"Edit",action:nil,keyEquivalent:"")
        let edit=NSMenu(title:"Edit")
        let copy=NSMenuItem(title:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(copy);item.submenu=edit;root.addItem(item)
        MenuLocalization.localize(root)
        precondition(item.title=="编辑" && edit.title=="编辑" && copy.title=="复制")
        precondition(copy.action == #selector(NSText.copy(_:)) && copy.keyEquivalent=="c")
        MenuLocalization.localize(root)
        precondition(copy.title=="复制")
        print("PASS: Chinese menus preserve native selectors and shortcuts")
    }
}
