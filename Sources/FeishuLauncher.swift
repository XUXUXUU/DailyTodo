import AppKit

enum FeishuLauncher {
    static func open(completion:@escaping (String?) -> Void) {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.electron.lark") else {
            completion("已复制，但未找到飞书，请先安装飞书。")
            return
        }
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=true
        NSWorkspace.shared.openApplication(at:url,configuration:configuration) { app,error in
            DispatchQueue.main.async {
                Runtime.report("feishu-launch",payload:[
                    "opened":app != nil && error == nil,
                    "bundle":app?.bundleIdentifier ?? "",
                    "error":error?.localizedDescription ?? ""
                ])
                completion(error.map { "已复制，但唤起飞书失败：\($0.localizedDescription)" })
            }
        }
    }
}
