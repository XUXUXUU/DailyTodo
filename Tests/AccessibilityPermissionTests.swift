import Foundation

@main enum AccessibilityPermissionTests {
    static func main() {
        var count=0
        func check(_ value:Bool,_ name:String) {precondition(value,name);count += 1;print("PASS:",name)}
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:nil) == .checking,"未完成真实检测不能解锁")
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:false) == .notGranted,"旧签名开关不能冒充当前授权")
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:true) == .restartRequired,"新进程允许但旧进程未生效提示重启")
        check(AccessibilityPermissionStatus.evaluate(current:true,fresh:true) == .allowed,"两次真实检查均允许才解锁")
        check(AccessibilityPermissionStatus.evaluate(current:true,fresh:false) == .notGranted,"撤销后的旧进程缓存不能冒充授权")
        check(!AccessibilityPermissionStatus.restartRequired.ready,"待重启不提前启用功能")
        check(!AccessibilityPermissionStatus.checking.ready,"检测过程中不能发送")
        check(AccessibilityPermissionStatus.allowed.ready,"确认授权后允许设置和测试")
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:false,access:.allowed) == .allowed,"真实跨应用读取成功不能被旧false缓存否决")
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:nil,access:.allowed) == .allowed,"实际访问可用不依赖子进程诊断")
        check(AccessibilityPermissionStatus.evaluate(current:true,fresh:false,access:.denied) == .notGranted,"实际API禁用不能被旧true缓存冒充")
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:true,access:.denied) == .restartRequired,"当前API禁用但新进程允许需重启")
        check(AccessibilityPermissionStatus.evaluate(current:false,fresh:nil,access:.unknown) == .checking,"IPC未知错误不能假装获得权限")
        var guide=AccessibilityGuideContinuation()
        check(guide.take(ready:true,setupOwnsFocus:true) == .none,"未打开助手时不能自动抢焦点")
        guide.begin()
        check(guide.take(ready:false,setupOwnsFocus:true) == .none,"尚未实际授权不能结束助手")
        check(guide.take(ready:true,setupOwnsFocus:true) == .returnToApp,"授权成功且仍在设置流程时自动返回")
        check(guide.take(ready:true,setupOwnsFocus:true) == .none,"同一次授权只返回一次")
        guide.begin()
        check(guide.take(ready:true,setupOwnsFocus:false) == .closeQuietly,"已去其他应用时只收起助手")
        check(guide.take(ready:true,setupOwnsFocus:true) == .none,"安静关闭后不会延迟抢回焦点")
        guide.begin();guide.cancel()
        check(guide.take(ready:true,setupOwnsFocus:true) == .none,"手动关闭取消后续自动返回")
        guide.begin()
        check(guide.take(ready:true,setupOwnsFocus:true) == .returnToApp,"重新打开助手可开始新的单次续接")
        print("PERMISSION TOTAL:",count)
    }
}
