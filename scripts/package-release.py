#!/usr/bin/env python3
"""Create signed Sparkle assets from a built app. Signing keys stay outside dist."""
from pathlib import Path
import datetime, hashlib, html, os, plistlib, subprocess, sys, xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
app=root/"build/DailyTodo.app"
info=plistlib.loads((app/"Contents/Info.plist").read_bytes())
if info.get("DailyTodoIntegrationBuild") or info["CFBundleIdentifier"]!="com.personal.dailytodo":
    raise SystemExit("Refusing to publish a test build")
version=info["CFBundleShortVersionString"]
build=info["CFBundleVersion"]
key=Path(os.environ["SPARKLE_PRIVATE_KEY_FILE"]).expanduser().resolve()
actual=subprocess.check_output(["swift",str(root/"scripts/public-update-key.swift"),str(key)],text=True).strip()
if actual!=info["SUPublicEDKey"]:
    raise SystemExit("The signing key does not match the public key embedded in the app")
notes_file=Path(os.environ.get("RELEASE_NOTES_FILE",root/f"release-notes/{version}.md"))
notes=notes_file.read_text()
out=root/"dist";out.mkdir(exist_ok=True)
archive=out/f"DailyTodo-{version}.zip"
subprocess.run(["ditto","-c","-k","--sequesterRsrc","--keepParent",str(app),str(archive)],check=True)
sign=root/"Vendor/Sparkle/bin/sign_update"
signature=subprocess.check_output([str(sign),"--ed-key-file",str(key),"-p",str(archive)],text=True).strip()
subprocess.run([str(sign),"--verify","--ed-key-file",str(key),str(archive),signature],check=True)
namespace="http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle",namespace)
rss=ET.Element("rss",{"version":"2.0"})
channel=ET.SubElement(rss,"channel")
ET.SubElement(channel,"title").text="Daily Todo"
ET.SubElement(channel,"language").text="zh-cn"
item=ET.SubElement(channel,"item")
ET.SubElement(item,"title").text=f"Daily Todo {version}"
ET.SubElement(item,"pubDate").text=datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
ET.SubElement(item,f"{{{namespace}}}version").text=build
ET.SubElement(item,f"{{{namespace}}}shortVersionString").text=version
ET.SubElement(item,f"{{{namespace}}}minimumSystemVersion").text=info["LSMinimumSystemVersion"]
bullets="".join(f"<li>{html.escape(line[2:])}</li>" for line in notes.splitlines() if line.startswith("- "))
ET.SubElement(item,"description").text="<h3>本次更新</h3><ul>"+bullets+"</ul>"
ET.SubElement(item,"enclosure",{
    "url":f"https://github.com/XUXUXUU/DailyTodo/releases/download/v{version}/{archive.name}",
    f"{{{namespace}}}edSignature":signature,
    "length":str(archive.stat().st_size),"type":"application/octet-stream"})
feed=out/"appcast.xml"
ET.ElementTree(rss).write(feed,encoding="utf-8",xml_declaration=True)
subprocess.run([str(sign),"--ed-key-file",str(key),str(feed)],check=True)
subprocess.run([str(sign),"--verify","--ed-key-file",str(key),str(feed)],check=True)
stage=root/"build-dmg";stage.mkdir(exist_ok=True)
subprocess.run(["ditto",str(app),str(stage/"DailyTodo.app")],check=True)
if not (stage/"Applications").exists():(stage/"Applications").symlink_to("/Applications")
(stage/"安装说明.txt").write_text("将 DailyTodo 拖到 Applications 完成首次安装。之后使用应用内“检查更新…”查看更新内容并安装。\n")
dmg=out/f"DailyTodo-{version}.dmg"
subprocess.run(["hdiutil","create","-volname",f"Daily Todo {version}","-srcfolder",str(stage),"-ov","-format","UDZO",str(dmg)],check=True)
(out/"SHA256SUMS").write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in [archive,dmg,feed]))
print(f"Prepared {version} ({build}), signed archive and feed")
