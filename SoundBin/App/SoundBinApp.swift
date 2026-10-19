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
            SoundBinCommands(model: appDelegate.model, updater: appDelegate.updater)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    #if DEBUG
    let updater = Updater(delegate: UpdateLog())
    #else
    let updater = Updater()
    #endif

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
        DebugLaunchOptions.apply(to: model, updater: updater)
        // Scripted runs report this in `updates dump` instead, since the alert would stop the script.
        if UserDefaults.standard.string(forKey: "SBScript") != nil { return }
        #endif
        // Say so straight away if SoundBin can't update from where it is, rather than failing quietly later.
        if let problem = InstallLocation.problem {
            DispatchQueue.main.async { InstallLocation.showAlert(for: problem) }
        }
    }
}
