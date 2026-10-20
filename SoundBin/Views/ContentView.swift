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
/// Hiding that space keeps SwiftUI's own button, with its menu command and saved state. Removing the space
/// instead makes SwiftUI add it back the first time the sidebar toggles, and moving the button in front of
/// it pushes the button into the toolbar's overflow menu.
private struct SidebarButtonPin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ nsView: PinView, context: Context) {}

    final class PinView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            // Hide the space as it's added, before it's ever drawn. This view exists before SwiftUI fills in the toolbar.
            NotificationCenter.default.addObserver(self, selector: #selector(toolbarWillAddItem(_:)),
                                                   name: NSToolbar.willAddItemNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func toolbarWillAddItem(_ notification: Notification) {
            guard let toolbar = notification.object as? NSToolbar,
                  let item = notification.userInfo?["item"] as? NSToolbarItem,
                  let index = notification.userInfo?["newIndex"] as? Int else { return }
            let items = toolbar.items
            // When the window opens, SwiftUI adds the space and then the button; a space added later in front of the button counts too.
            if Self.isSidebarButton(item), items.indices.contains(index - 1), items[index - 1].itemIdentifier == .flexibleSpace {
                items[index - 1].isHidden = true
            } else if item.itemIdentifier == .flexibleSpace, items.indices.contains(index), Self.isSidebarButton(items[index]) {
                item.isHidden = true
            }
        }

        private static func isSidebarButton(_ item: NSToolbarItem) -> Bool {
            item.itemIdentifier.rawValue.hasSuffix(".toggleSidebar")
        }
    }
}
