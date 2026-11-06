#!/usr/bin/env python3
"""真实通知探针：前台/后台/有正式计划，均用独立UUID，不清空正式用户记录或权限。"""
import json, os, pathlib, plistlib, signal, subprocess, time, uuid
root=pathlib.Path(__file__).resolve().parents[1]
app=root/'build-integration/DailyTodo.app'
test_info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if not test_info.get("DailyTodoIntegrationBuild") or test_info.get("CFBundleIdentifier") != "com.personal.dailytodo.testing":
    raise SystemExit("拒绝共享正式通知身份的测试应用")
results=[]
for mode in ['foreground','background','foreground_with_plan']:
    session=str(uuid.uuid4()).upper()
    folder=pathlib.Path.home()/'Library/Application Support/DailyTodoTesting'/session
    args=['open','-n',str(app),'--args','--integration-session',session,'--integration-test-notification']
    if mode=='background':args+=['--integration-background-test']
    if mode=='foreground_with_plan':args+=['--integration-test-preserve-plan']
    pid=None
    try:
        subprocess.run(args,check=True)
        deadline=time.monotonic()+45
        while not (folder/'notification-probe-finished.json').exists() and time.monotonic()<deadline:time.sleep(.25)
        record=json.loads((folder/'notification-probe.json').read_text())
        record['mode']=mode;record['session']=session
        assert record['submitted'],record
        assert record['activeAtSubmission']==(mode!='background'),record
        assert len(record['delivered'])==1,record
        assert record['delivered'][0]['title']=='测试提醒 · 该给瑶总发 Todo 啦！' and record['delivered'][0]['body']=='这是一条测试提醒'
        for key in ['formalPlanUnchanged','settingsUnchanged','dedupUnchanged','historyUnchanged','nextReminderUnchanged']:assert record[key],record
        if mode=='foreground_with_plan':assert record['beforeFormalCount']==record['afterFormalCount']==0
        delegate=folder/'foreground-notification.json'
        record['foregroundDelegateObserved']=delegate.exists()
        if mode!='background':assert delegate.exists(),record
        record['passed']=True
        results.append(record);print('PASS:',mode,flush=True)
    except Exception as exc:
        results.append({'mode':mode,'session':session,'passed':False,'error':str(exc)})
        print('FAIL:',mode,exc,flush=True)
    finally:
        if (folder/'app-launched.json').exists():
            pid=json.loads((folder/'app-launched.json').read_text())['pid']
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
        subprocess.run([str(app/'Contents/MacOS/DailyTodo'),'--background','--integration-session',session,'--integration-cleanup'],timeout=25,check=True)
(root/'notification-test-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
print(json.dumps(results,ensure_ascii=False,indent=2))
if not all(x['passed'] for x in results):raise SystemExit(1)
