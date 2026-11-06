import SwiftUI
import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController
    let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater:Runtime.sessionID == nil,
            updaterDelegate:nil,userDriverDelegate:nil)
        controller.updater.publisher(for:\.canCheckForUpdates)
            .receive(on:RunLoop.main)
            .assign(to:&$canCheck)
    }

    func check() { controller.checkForUpdates(nil) }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject var updater:AppUpdater
    var body:some View {
        Button("检查更新…") { updater.check() }.disabled(!updater.canCheck)
    }
}
