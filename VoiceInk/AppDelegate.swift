import Cocoa
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.currentMainWindow() != nil {
                WindowManager.shared.showMainWindow()
                return false
            }

            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
            return false
        }

        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?
    private var inboxCompanionBridge: InboxCompanionBridge?
    private var pendingInboxCompanionURLs: [URL] = []

    func configureInboxCompanionBridge(_ bridge: InboxCompanionBridge) {
        inboxCompanionBridge = bridge
        let pendingURLs = pendingInboxCompanionURLs
        pendingInboxCompanionURLs.removeAll()
        pendingURLs.forEach(bridge.handle)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let partition = Self.partitionOpenURLs(urls)
        let companionURLs = partition.companion
        if !companionURLs.isEmpty {
            if let inboxCompanionBridge {
                companionURLs.forEach(inboxCompanionBridge.handle)
            } else {
                pendingInboxCompanionURLs.append(contentsOf: companionURLs)
            }
        }

        let remainingURLs = partition.remaining
        guard !remainingURLs.isEmpty else { return }

        guard let url = remainingURLs.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }

        if let menuBarManager {
            menuBarManager.activateForPresentedWindow()
        } else {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI's main window scene and let ContentView process this later.
            pendingOpenFileURL = url
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            WindowManager.shared.showMainWindow()
            NotificationCenter.default.post(
                name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }

    static func partitionOpenURLs(_ urls: [URL]) -> (companion: [URL], remaining: [URL]) {
        urls.reduce(into: (companion: [URL](), remaining: [URL]())) { result, url in
            if InboxCompanionBridge.isCompanionURL(url) {
                result.companion.append(url)
            } else {
                result.remaining.append(url)
            }
        }
    }
}
