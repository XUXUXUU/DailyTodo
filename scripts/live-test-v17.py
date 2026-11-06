#!/usr/bin/env python3
"""两份隔离计划同刻运行：一份可提醒，一份已复制且退出。真实本地时间，不修改系统时钟。"""
import datetime,json,os,pathlib,plistlib,subprocess,time,uuid,signal
root=pathlib.Path(__file__).resolve().parents[1];app=root/'build-integration/DailyTodo.app';binary=app/'Contents/MacOS/DailyTodo'
test_info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if not test_info.get("DailyTodoIntegrationBuild") or test_info.get("CFBundleIdentifier") != "com.personal.dailytodo.testing":
    raise SystemExit("拒绝共享正式通知身份的测试应用")
target=(datetime.datetime.now().astimezone()+datetime.timedelta(minutes=2)).replace(second=0,microsecond=0)
if target.weekday()>4:raise SystemExit('周末不能运行真实工作日日历测试')
result={'target':target.isoformat(),'profiles':[]};children=[]
try:
 for completed in [False,True]:
  uid=str(uuid.uuid4()).upper();folder=pathlib.Path.home()/'Library/Application Support/DailyTodoTesting'/uid
  args=['open','-n',str(app),'--args','--integration-session',uid,'--integration-install',target.strftime('%H:%M')]
  if completed:args+=['--integration-complete-before-exit']
  item={'session':uid,'completed':completed};result['profiles'].append(item)
  subprocess.run(args,check=True)
  end=time.monotonic()+55
  while not (folder/'integration-ready.json').exists() and time.monotonic()<end:time.sleep(.2)
  assert (folder/'integration-ready.json').exists(),str(folder)
  pid=json.loads((folder/'app-launched.json').read_text())['pid'];os.kill(pid,15);time.sleep(.4)
  item['installPID']=pid;item['installLaunchTime']=(folder/'app-launched.json').stat().st_mtime
  children.append((uid,folder))
 print('已注册两份真实日历计划，应用均退出；等待 '+target.isoformat(),flush=True)
 deadline=time.monotonic()+200
 while time.monotonic()<deadline:
  first=children[0][1];second=children[1][1]
  events=second/'ReminderState/reminder-events.jsonl'
  if (first/'automatic-popup.json').exists() and events.exists() and 'agent-preflight' in events.read_text() and 'alreadyCopied' in events.read_text():break
  time.sleep(1)
 first=children[0][1];second=children[1][1]
 popup=json.loads((first/'automatic-popup.json').read_text());result['popup']=popup
 fired=datetime.datetime.fromisoformat(popup['timestamp'].replace('Z','+00:00'))
 assert 0<=(fired-target).total_seconds()<65
 assert popup['pid']!=result['profiles'][0]['installPID']
 assert not (second/'automatic-popup.json').exists()
 assert (second/'app-launched.json').stat().st_mtime==result['profiles'][1]['installLaunchTime']
 assert 'alreadyCopied' in (second/'ReminderState/reminder-events.jsonl').read_text()
 result['realColdStartPopup']=True;result['completedHelperSkippedWithoutStartingApp']=True;result['passed']=True
except Exception as exc:result['passed']=False;result['error']=str(exc)
finally:
 for uid,folder in children:
  if (folder/'app-launched.json').exists():
   pid=json.loads((folder/'app-launched.json').read_text())['pid']
   try:os.kill(pid,15)
   except ProcessLookupError:pass
  subprocess.run([str(binary),'--background','--integration-session',uid,'--integration-cleanup'],timeout=30,check=True)
  cleanup=json.loads((folder/'cleanup-notifications.json').read_text())
  next(p for p in result['profiles'] if p['session']==uid)['notificationCleanup']=cleanup
 if result.get('passed'):
  a,b=result['profiles'];assert len(a['notificationCleanup']['delivered'])==1 and not b['notificationCleanup']['delivered']
 (root/'live-reminder-tests-v1.7.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
if not result['passed']:raise SystemExit(1)
