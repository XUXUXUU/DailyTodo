import AppKit

/// Translate the app's generated menus while preserving native actions and shortcuts.
enum MenuLocalization {
    private static let titles = [
        "Edit":"编辑", "View":"显示", "Window":"窗口", "Help":"帮助",
        "Services":"服务", "Undo":"撤销", "Redo":"重做", "Cut":"剪切",
        "Copy":"复制", "Paste":"粘贴", "Paste and Match Style":"粘贴并匹配样式",
        "Delete":"删除", "Select All":"全选", "Find":"查找",
        "Find…":"查找…", "Find Next":"查找下一个", "Find Previous":"查找上一个",
        "Use Selection for Find":"使用选定内容查找", "Jump to Selection":"跳转到选定内容",
        "Minimize":"最小化", "Zoom":"缩放", "Bring All to Front":"前置全部窗口",
        "Close":"关闭", "Close Window":"关闭窗口",
        "Enter Full Screen":"进入全屏幕", "Exit Full Screen":"退出全屏幕",
        "Show Tab Bar":"显示标签页栏", "Hide Tab Bar":"隐藏标签页栏",
        "Show All Tabs":"显示全部标签页", "Merge All Windows":"合并所有窗口",
        "Move Tab to New Window":"将标签页移到新窗口",
        "Show Previous Tab":"显示上一个标签页", "Show Next Tab":"显示下一个标签页",
        "Start Dictation…":"开始听写…", "Emoji & Symbols":"表情与符号",
        "About Daily Todo":"关于 Daily Todo", "Hide Daily Todo":"隐藏 Daily Todo",
        "Hide Others":"隐藏其他", "Show All":"显示全部", "Quit Daily Todo":"退出 Daily Todo",
        "Daily Todo Help":"Daily Todo 帮助"
    ]

    static func localize(_ menu:NSMenu) {
        if let title=titles[menu.title] { menu.title=title }
        for item in menu.items {
            if let title=titles[item.title] { item.title=title }
            if let submenu=item.submenu { localize(submenu) }
        }
    }
}
