import Foundation

@main enum FeishuAutomationTests {
    static func main() throws {
        var count=0
        func check(_ value:Bool,_ name:String) { precondition(value,name);count += 1;print("PASS:",name) }
        let suite="DailyTodo.FeishuTest."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        prefs.set(true,forKey:"openFeishuAfterCopy")
        var config=FeishuAutomationConfiguration.load(from:prefs)
        check(!config.enabled && config.mode == .draft,"旧唤起权限不升级为自动发送")
        config.enabled=true;config.recipient="  测试收件人  ";config.mode = .send
        try config.save(to:prefs)
        let loaded=FeishuAutomationConfiguration.load(from:prefs)
        check(loaded.enabled && loaded.recipient == "测试收件人" && loaded.mode == .send,"完整配置重建后保持")
        check(loaded.buttonTitle == "发给测试收件人","按钮跟随自定义收件人")
        check(FeishuAutomationConfiguration().buttonTitle == "发给瑶总","默认按钮称谓")
        var invalid=loaded;invalid.recipient="\n"
        check((try? invalid.save(to:prefs)) == nil,"空收件人不能覆盖有效配置")
        check(FeishuAutomationConfiguration.load(from:prefs).recipient == "测试收件人","验证失败保留原设置")
        check(FeishuAutomationRules.normalized("\u{200b} \n\u{feff}").isEmpty,"空编辑器零宽字符不算草稿")
        check(FeishuAutomationRules.recipientMatches("发送给 测试收件人",name:"测试收件人",isSelf:false),"准确聊天输入区")
        check(!FeishuAutomationRules.recipientMatches("发送给 测试收件人助理",name:"测试收件人",isSelf:false),"相似姓名不能通过核对")
        check(!FeishuAutomationRules.recipientMatches("可以向自己发送文件或转发消息",name:"其他人",isSelf:false),"自己输入区不能冒充其他联系人")
        check(FeishuAutomationRules.recipientMatches("可以向自己发送文件或转发消息",name:"安龙",isSelf:true),"明确自己联系人允许专用输入区")
        check(FeishuAutomationRules.canSendUsingReturn(hint:"Shift + Enter 换行"),"识别实际发送键")
        check(!FeishuAutomationRules.canSendUsingReturn(hint:"Enter 换行"),"不猜测未知发送键")
        check(!FeishuAutomationRules.canSendUsingReturn(hint:""),"无键位线索不发送")
        check(FeishuAutomationRules.isEmptyDraft("\u{200b}\n"),"空草稿可填写")
        check(!FeishuAutomationRules.isEmptyDraft("未完成的消息"),"保留已有草稿")
        check(FeishuAutomationRules.uniqueExactMatch(["测试收件人","测试收件人助理"],name:"测试收件人") == 0,"联系人只接受精确姓名")
        check(FeishuAutomationRules.uniqueExactMatch(["测试收件人","测试收件人"],name:"测试收件人") == nil,"同名联系人阻止自动选择")
        check(FeishuAutomationRules.uniqueExactMatch(["其他人"],name:"测试收件人") == nil,"无匹配联系人不回退首项")
        check(FeishuAutomationRules.mayFill(header:"测试收件人",description:"发送给 测试收件人",name:"测试收件人",isSelf:false,draft:"",focused:true),"现场空输入区允许写入")
        check(!FeishuAutomationRules.mayFill(header:"测试收件人",description:"发送给 测试收件人",name:"测试收件人",isSelf:false,draft:"刚输入的新草稿",focused:true),"聚焦期间新输入草稿不能覆盖")
        check(!FeishuAutomationRules.mayFill(header:"其他人",description:"发送给 测试收件人",name:"测试收件人",isSelf:false,draft:"",focused:true),"消息正文姓名不代替聊天标题")
        check(!FeishuAutomationRules.mayFill(header:"测试收件人",description:"发送给 测试收件人",name:"测试收件人",isSelf:false,draft:"",focused:false),"失去当前输入焦点不写入")
        check(!FeishuAutomationRules.mayFill(header:"测试收件人",description:"发送给 测试收件人",name:"测试收件人",isSelf:false,draft:"",focused:true,readable:false),"读不到草稿不能当作空草稿")
        check(FeishuAutomationRules.isEmptyComposer("可以向自己发送文件或转发消息\u{200b}\n",name:"安龙",isSelf:true,readable:true,editableText:false),"只读占位提示不是正文")
        check(!FeishuAutomationRules.isEmptyComposer("可以向自己发送文件或转发消息\u{200b}\n",name:"安龙",isSelf:true,readable:true,editableText:true),"用户真的输入占位词也必须保留")
        check(!FeishuAutomationRules.isEmptyComposer("发送给其他人",name:"目标",isSelf:false,readable:true,editableText:false),"其他人的占位提示不能通过核对")
        check(!FeishuAutomationRules.isEmptyComposer("",name:"目标",isSelf:false,readable:false,editableText:false),"读不到输入区不能继续")
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let ledger=FeishuDeliveryLedger(directory:dir)
        let id=FeishuDeliveryLedger.fingerprint(recipient:"A",day:"2026-11-06",text:"正文一")
        check(try !ledger.hasAttempt(id),"未发送内容可在操作聊天前检查")
        check(try ledger.claim(id),"首次发送原子占位")
        check(try ledger.hasAttempt(id),"操作聊天前识别重复内容")
        check(try !ledger.claim(id),"未确认发送禁止重试")
        check(try !FeishuDeliveryLedger(directory:dir).claim(id),"重启后仍阻止重复发送")
        try ledger.finish(id,sent:true)
        check(try !ledger.claim(id),"已发送正文禁止重复")
        check(try ledger.claim(FeishuDeliveryLedger.fingerprint(recipient:"A",day:"2026-11-06",text:"正文二")),"修改正文允许新发送")
        check(try ledger.claim(FeishuDeliveryLedger.fingerprint(recipient:"B",day:"2026-11-06",text:"正文一")),"不同收件人独立去重")
        check(try ledger.claim(FeishuDeliveryLedger.fingerprint(recipient:"A",day:"2026-11-09",text:"正文一")),"下一工作日不受旧发送影响")
        try Data("broken".utf8).write(to:dir.appendingPathComponent("feishu-deliveries.json"))
        check((try? ledger.claim("another")) == nil,"损坏账本停止发送而非清空去重")
        print("FEISHU TOTAL:",count)
    }
}
