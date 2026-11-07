import AppKit
import ServiceManagement
import SwiftUI

@main
struct LivewallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = Store.shared

    var body: some Scene {
        Window("Livewall", id: "library") {
            LibraryView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                OpenPageButton(title: "Settings…", page: .settings).keyboardShortcut(",")
            }
        }

        MenuBarExtra {
            StatusMenu().environmentObject(store)
        } label: {
            MenuBarLabel(paused: store.userPaused)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: WallpaperManager?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = WallpaperManager(store: .shared)
        // Stay quietly in the menu bar when started at login; otherwise show the library.
        if !launchedAtLogin { WindowOpener.shared.openLibrary() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowOpener.shared.openLibrary()
        return false
    }

    /// Videos dropped on the app icon or opened with "Open With → Livewall".
    func application(_ application: NSApplication, open urls: [URL]) {
        Store.shared.requestedPage = .videos
        WindowOpener.shared.openLibrary()
        Task { await Store.shared.importVideos(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Lets AppKit code open the SwiftUI library window.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private var open: (() -> Void)?
    private var pending = false

    func register(_ action: @escaping () -> Void) {
        open = action
        if pending { pending = false; openLibrary() }
    }

    func openLibrary() {
        guard let open else { pending = true; return }
        open()
        NSApp.activate()
    }
}

/// The menu bar icon. It is on screen from launch, so it hands the window opener to AppKit.
struct MenuBarLabel: View {
    let paused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: paused ? "pause.rectangle" : "play.rectangle.on.rectangle")
            .onAppear { WindowOpener.shared.register { openWindow(id: "library") } }
    }
}

struct OpenPageButton: View {
    let title: String
    let page: SidebarItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            Store.shared.requestedPage = page
            openWindow(id: "library")
            NSApp.activate()
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Store.shared.alertMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        Store.shared.objectWillChange.send()
    }
}

struct StatusMenu: View {
    @EnvironmentObject var store: Store

    private var quickPicks: [Wallpaper] {
        let favorites = store.wallpapers.filter(\.favorite)
        return Array((favorites.isEmpty ? store.wallpapers : favorites).prefix(15))
    }

    var body: some View {
        Text(store.status)
        Divider()
        OpenPageButton(title: "Open Livewall…", page: .all).keyboardShortcut("o")
        Button(store.userPaused ? "Resume Wallpapers" : "Pause Wallpapers") { store.userPaused.toggle() }
            .keyboardShortcut("p")
        Button("Next Wallpaper") { store.nextWallpaper() }
            .keyboardShortcut("n")
        Toggle("Sound", isOn: $store.settings.soundOn)
        Menu("Quick Switch") {
            ForEach(quickPicks) { wp in
                Button(wp.title) { store.apply(wp, to: Store.allDisplays) }
            }
        }
        Divider()
        Button("Remove Wallpaper") { store.removeAllWallpapers() }
            .disabled(store.assignments.isEmpty)
        Toggle("Launch at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
        OpenPageButton(title: "Settings…", page: .settings).keyboardShortcut(",")
        Divider()
        Button("Quit Livewall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
