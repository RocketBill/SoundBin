import AppKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            BrowserView()
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(SidebarButtonPin())
    }
}

/// Keeps the sidebar button beside the window controls whether the sidebar is open or closed.
///
/// SwiftUI puts a flexible space in front of the button, which pushes it to the sidebar's far edge while the
/// sidebar is open and back beside the window controls when it closes, so it jumps under the pointer.
/// Removing that space keeps SwiftUI's own button, with its menu command and saved state.
/// (Moving the button in front of the space instead pushes it into the toolbar's overflow menu.)
private struct SidebarButtonPin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ nsView: PinView, context: Context) {}

    final class PinView: NSView {
        private var toolbarObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let toolbarObserver { NotificationCenter.default.removeObserver(toolbarObserver) }
            toolbarObserver = nil
            guard window != nil else { return }
            // SwiftUI fills in the toolbar after this view joins the window, and may rebuild it later.
            toolbarObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // The item isn't in the toolbar until this notification has been delivered.
                DispatchQueue.main.async { self?.pin() }
            }
            DispatchQueue.main.async { self.pin() }
        }

        private func pin() {
            guard let toolbar = window?.toolbar,
                  let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue.hasSuffix(".toggleSidebar") }),
                  index > 0, toolbar.items[index - 1].itemIdentifier == .flexibleSpace else { return }
            toolbar.removeItem(at: index - 1)
        }
    }
}
