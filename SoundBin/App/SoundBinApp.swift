import SwiftUI

@main
struct SoundBinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SoundBin", id: "main") {
            ContentView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            SoundBinCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// Folders dropped on the Dock icon or opened with "Open With › SoundBin" in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            model.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugLaunchOptions.apply(to: model)
        #endif
    }
}
