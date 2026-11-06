import AppKit

@main enum AccessibilityGuideTests {
    static func main() {
        var count=0
        func check(_ value:Bool,_ name:String) {precondition(value,name);count += 1;print("PASS:",name)}
        let primary=AccessibilityGuidePositioning.appKitFrame(fromQuartz:CGRect(x:100,y:40,width:720,height:960),primaryScreenTop:1080)
        check(primary == NSRect(x:100,y:80,width:720,height:960),"主屏窗口坐标与截图顶部方向对应")
        let above=AccessibilityGuidePositioning.appKitFrame(fromQuartz:CGRect(x:0,y:-900,width:700,height:800),primaryScreenTop:1080)
        check(above.minY>1080,"上方副屏不会翻转到主屏下方")
        let below=AccessibilityGuidePositioning.appKitFrame(fromQuartz:CGRect(x:0,y:1200,width:700,height:800),primaryScreenTop:1080)
        check(below.maxY<0,"下方副屏保持负坐标")
        let size=NSSize(width:310,height:190)
        let left=NSRect(x:-1920,y:0,width:1920,height:1080)
        let leftResult=AccessibilityGuidePositioning.frame(panelSize:size,settingsFrame:NSRect(x:-1800,y:300,width:700,height:700),visibleFrame:left)
        check(left.contains(leftResult),"左侧副屏指引完整留在当前屏幕")
        let screen=NSRect(x:0,y:25,width:1440,height:1000)
        let upper=NSRect(x:200,y:500,width:720,height:500)
        let under=AccessibilityGuidePositioning.frame(panelSize:size,settingsFrame:upper,visibleFrame:screen)
        check(under.maxY<upper.minY && under.size==size,"有空间时位于设置窗口下方且固定尺寸")
        let full=NSRect(x:100,y:25,width:720,height:1000)
        let inside=AccessibilityGuidePositioning.frame(panelSize:size,settingsFrame:full,visibleFrame:screen)
        check(full.contains(inside) && screen.contains(inside),"无下方空间时贴在窗口内侧")
        let outside=AccessibilityGuidePositioning.frame(panelSize:size,settingsFrame:NSRect(x:2000,y:-2000,width:720,height:1000),visibleFrame:screen)
        check(screen.contains(outside) && outside.size==size,"异常窗口位置仍保持可见且不可撑大")
        let fallback=AccessibilityGuidePositioning.frame(panelSize:size,settingsFrame:nil,visibleFrame:left)
        check(left.contains(fallback),"读不到窗口元数据时仍留在安全屏幕")
        print("GUIDE TOTAL:",count)
    }
}
