import Foundation

@main struct ShortcutTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError(name) }
            count += 1
            print("PASS \(name)")
        }
        let defaults = EditorShortcuts.standard
        let enter = EditorKey(code: 36)
        let tab = EditorKey(code: 48)
        let ctrlShiftK = EditorKey(code: 40, modifiers: [.control, .shift])
        check(defaults.action(for: enter) == .newline, "默认Enter换行")
        check(defaults.action(for: tab) == .next, "默认Tab下一栏")
        check(EditorKey(code: 76) == enter, "小键盘Enter规范化")
        check(defaults.action(for: tab, marked: true) == nil, "IME组合期不切栏")
        check(defaults.action(for: enter, marked: true) == nil, "IME组合期不换行")
        check(defaults.action(for: tab, repeating: true) == nil, "Tab长按不重复切栏")
        check(defaults.action(for: enter, repeating: true) == nil, "Return长按只处理首次")
        check(defaults.action(for: .previous) == .previous, "Shift+Tab固定返回")
        check(EditorKey.previous.validationMessage != nil, "Shift+Tab不能录制")
        check(EditorKey(code: 0).validationMessage != nil, "拒绝裸字母")
        check(EditorKey(code: 18).validationMessage != nil, "拒绝裸数字")
        check(EditorKey(code: 43).validationMessage != nil, "拒绝裸标点")
        check(EditorKey(code: 53).validationMessage != nil, "Esc保留取消")
        for code: UInt16 in [48, 49, 12, 13, 8, 9, 7, 6, 0] {
            check(EditorKey(code: code, modifiers: .command).validationMessage != nil, "保留Command组合 \(code)")
        }
        check(EditorKey(code: 49, modifiers: .control).validationMessage != nil, "输入法切换保留")
        check(EditorKey(code: 40, modifiers: [.control, .option]).validationMessage != nil, "VoiceOver组合保留")
        check(EditorKey(code: 40, modifiers: [.shift, .option]).validationMessage != nil, "可产生字符的组合保留")
        check(ctrlShiftK.validationMessage == nil, "允许Ctrl+Shift+字母")
        check(defaults.issue(with: tab, for: .newline)?.contains("下一栏") == true, "冲突提示指向现有动作")
        let custom = EditorShortcuts(newline: ctrlShiftK, next: .init(code: 36, modifiers: .shift))
        check(custom.isValid && custom.action(for: ctrlShiftK) == .newline, "自定义换行")
        check(custom.action(for: .init(code: 76, modifiers: .shift)) == .next, "规范化自定义下一栏")
        check(custom.action(for: tab) == nil, "替换后原Tab交还文本系统")
        check(custom.action(for: .init(code: 8, modifiers: .command)) == nil, "自定义不截获原生复制")
        let suite = "com.personal.dailytodo.shortcuts.test.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        check(EditorShortcuts.load(from: preferences) == defaults, "无历史偏好默认键位")
        preferences.set("standard", forKey: "editingMode")
        check(EditorShortcuts.load(from: preferences) == defaults, "旧标准迁移新版默认")
        preferences.set("quick", forKey: "editingMode")
        preferences.set(23, forKey: "reminderMinute")
        let migrated = EditorShortcuts.load(from: preferences)
        check(migrated.next == enter && migrated.newline == EditorKey(code: 36, modifiers: .shift), "旧快速模式保留")
        try custom.save(to: preferences)
        check(EditorShortcuts.load(from: UserDefaults(suiteName: suite)!) == custom, "重建偏好实例自定义有效")
        check(preferences.integer(forKey: "reminderMinute") == 23, "独立提醒偏好")
        try defaults.save(to: preferences)
        check(EditorShortcuts.load(from: preferences) == defaults, "恢复默认优先于旧模式")
        let corrupt = EditorShortcuts(newline: tab, next: tab)
        do { try corrupt.save(to: preferences); fatalError("允许保存重复绑定") } catch {}
        check(EditorShortcuts.load(from: preferences) == defaults, "拒绝覆盖最后有效配置")
        preferences.set(try JSONEncoder().encode(corrupt), forKey: EditorShortcuts.storageKey)
        check(EditorShortcuts.load(from: preferences) == defaults, "损坏配置安全回退")
        print("TOTAL \(count)")
    }
}
