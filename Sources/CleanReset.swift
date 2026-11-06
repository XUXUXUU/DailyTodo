import Foundation
/// 必须由用户确认后的调用路径进入。只移动/备份本App精确路径，不读取备份重新填入。
enum CleanReset {
    static func backupAndClear(directory: URL, backupRoot: URL, preferences: Data, extraPaths: [URL] = []) throws -> URL {
        let manager = FileManager.default
        let name = ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-") + "-" + UUID().uuidString
        let backup = backupRoot.appendingPathComponent(name)
        try manager.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try preferences.write(to:backup.appendingPathComponent("Preferences.plist"),options:.atomic)
        try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.appendingPathComponent("Preferences.plist").path)
        var moved: [(URL,URL)] = []
        do {
            let paths = [directory] + extraPaths
            for (index,source) in paths.enumerated() where manager.fileExists(atPath:source.path) {
                let destination = backup.appendingPathComponent(index == 0 ? "Data" : source.lastPathComponent)
                try manager.moveItem(at:source,to:destination); moved.append((source,destination))
            }
            try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            return backup
        } catch {
            // 创建新目录前失败时，将所有已移动的数据放回原处。
            for (source,destination) in moved.reversed() where !manager.fileExists(atPath:source.path) { try? manager.moveItem(at:destination,to:source) }
            throw error
        }
    }
}
extension Notification.Name { static let dailyTodoCleanStart = Notification.Name("com.personal.dailytodo.clean-start") }

extension CleanReset {
    static func trashAndClear(directory:URL) throws {
        let manager=FileManager.default
        if manager.fileExists(atPath:directory.path) { try manager.trashItem(at:directory,resultingItemURL:nil) }
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
}
