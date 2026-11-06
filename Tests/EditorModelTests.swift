import AppKit
import Foundation
@main struct ModelTests16 {
 @MainActor static func main() async throws {
  let model=Model();var checks=[String:Bool]()
  model.edit(\.tasks,"old");model.edit(\.tasks,"最新中文");checks["dirtyBeforeFlush"]=model.versions.dirty
  checks["latestFlush"]=model.flush() && model.store?.entries.first(where:{$0.day==model.entry.day})?.tasks == "最新中文"
  model.edit(\.tasks,"复制时快照");_ = model.flush();model.edit(\.tasks,"复制后新输入")
  checks["copyThenTyping"]=model.entry.tasks == "复制后新输入" && model.versions.dirty && model.flush()
  model.edit(\.progress,"防抖A")
  try await Task.sleep(nanoseconds:1_000_000_000)
  model.edit(\.progress,"防抖B最新")
  try await Task.sleep(nanoseconds:2_300_000_000)
  checks["oldDebounceCannotSaveNewEarly"]=model.versions.dirty && model.store?.entries.first(where:{$0.day==model.entry.day})?.progress != "防抖B最新"
  try await Task.sleep(nanoseconds:1_100_000_000)
  checks["threeSecondDebounceLatest"] = !model.versions.dirty && model.store?.entries.first(where:{$0.day==model.entry.day})?.progress == "防抖B最新"
  let old=model.store!.entries.first(where:{$0.day==model.entry.day})!.tasks
  checks["reopenLatest"]=try Store(directory:model.directory).entry(day:model.entry.day).tasks == old
  let moved=model.directory.appendingPathExtension("temporarily-moved")
  try FileManager.default.moveItem(at:model.directory,to:moved)
  try Data([1]).write(to:model.directory)
  model.edit(\.tasks,"写失败仍保留")
  checks["failureRetainsDraft"] = !model.flush() && model.entry.tasks == "写失败仍保留" && model.saveStatus == "保存失败" && model.versions.dirty
  try FileManager.default.removeItem(at:model.directory);try FileManager.default.moveItem(at:moved,to:model.directory)
  checks["retryLatest"]=model.flush() && model.entry.tasks == "写失败仍保留" && !model.versions.dirty
  let view=DraftTextView();view.isRichText=false;view.allowsUndo=true;view.string="甲乙"
  view.setMarkedText("zhongwen",selectedRange:NSRange(location:8,length:0),replacementRange:NSRange(location:2,length:0))
  checks["nativeMarkedText"]=view.hasMarkedText()
  view.unmarkText();checks["nativeUnmarkCommits"]=view.string == "甲乙zhongwen"
  let yesterday=model.entry.day,previous=model.entry.tasks
  model.dayClock={Date().addingTimeInterval(86400)}
  model.edit(\.tasks,"新日内容");_ = model.flush()
  checks["foregroundMidnightKeepsHistory"]=model.entry.day != yesterday && model.store?.entries.first(where:{$0.day==yesterday})?.tasks == previous && model.entry.tasks == "新日内容"
  let failedDay=model.entry.day
  model.edit(\.tasks,"昨日未保存的修改")
  try FileManager.default.moveItem(at:model.directory,to:moved);try Data([1]).write(to:model.directory)
  model.dayClock={Date().addingTimeInterval(172800)};model.edit(\.tasks,"后天草稿")
  checks["failedMidnightRetainsOriginalDay"]=model.deferredDays[failedDay]?.tasks == "昨日未保存的修改" && model.entry.tasks == "后天草稿"
  try FileManager.default.removeItem(at:model.directory);try FileManager.default.moveItem(at:moved,to:model.directory)
  checks["failedMidnightRetriesBothDays"]=model.flush() && model.store?.entries.first(where:{$0.day==failedDay})?.tasks == "昨日未保存的修改" && model.store?.entries.first(where:{$0.day==model.entry.day})?.tasks == "后天草稿"
  let result=try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]);print(String(data:result,encoding:.utf8)!)
  if checks.values.contains(false){exit(1)}
 }
}
