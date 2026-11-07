import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window root

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @State private var selection: SidebarItem? = .all
    @State private var target = Store.allDisplays

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("All Wallpapers", systemImage: "square.grid.2x2").tag(SidebarItem.all)
                    Label("Favorites", systemImage: "heart").tag(SidebarItem.favorites)
                    Label("Animated Scenes", systemImage: "sparkles").tag(SidebarItem.scenes)
                    Label("My Videos", systemImage: "film").tag(SidebarItem.videos)
                }
                if !store.categories.isEmpty {
                    Section("Categories") {
                        ForEach(store.categories, id: \.self) { c in
                            Label(c, systemImage: "folder").tag(SidebarItem.category(c))
                        }
                    }
                }
                Section("Livewall") {
                    Label("Displays", systemImage: "display.2").tag(SidebarItem.displays)
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .safeAreaInset(edge: .bottom) { StatusFooter() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            switch selection ?? .all {
            case .displays: DisplaysView(target: $target)
            case .settings: SettingsView()
            default: GalleryView(filter: selection ?? .all, target: $target)
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            store.hasLaunchedBefore = true
            consumePageRequest()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onChange(of: store.requestedPage) { consumePageRequest() }
        .onChange(of: store.categories) {
            if case .category(let c) = selection, !store.categories.contains(c) { selection = .all }
        }
        .alert("Livewall", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    private func consumePageRequest() {
        if let page = store.requestedPage {
            selection = page
            store.requestedPage = nil
        }
    }
}

struct StatusFooter: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.status.hasPrefix("Playing") ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button {
                store.userPaused.toggle()
            } label: {
                Image(systemName: store.userPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(store.userPaused ? "Resume wallpapers" : "Pause wallpapers")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Gallery

struct GalleryView: View {
    let filter: SidebarItem
    @Binding var target: String
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var dropTargeted = false

    private var items: [Wallpaper] {
        store.wallpapers.filter { wp in
            switch filter {
            case .favorites: wp.favorite
            case .scenes: wp.isScene
            case .videos: !wp.isScene
            case .category(let c): wp.category == c
            default: true
            }
        }
        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
        .sorted { a, b in a.isScene != b.isScene ? !a.isScene : a.added > b.added }
    }

    private var importCategory: String {
        if case .category(let c) = filter { return c }
        return ""
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 380), spacing: 20)], spacing: 24) {
                ForEach(items) { wp in
                    WallpaperCard(wallpaper: wp, target: target)
                }
            }
            .padding(24)
        }
        .overlay { if items.isEmpty { emptyState } }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(Label("Drop videos to add them", systemImage: "square.and.arrow.down").font(.title3.weight(.semibold)))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .navigationTitle(filter.title)
        .navigationSubtitle("\(items.count) wallpaper\(items.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItem { TargetPicker(target: $target) }
            ToolbarItem {
                Button { store.nextWallpaper() } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Switch to a random wallpaper")
            }
            ToolbarItem {
                Button(action: addVideos) { Label("Add Videos", systemImage: "plus") }
                    .help("Add your own videos as wallpapers")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .favorites:
            ContentUnavailableView("No favorites yet", systemImage: "heart",
                                   description: Text("Hover a wallpaper and click the heart to save it here."))
        case .all, .videos, .category:
            ContentUnavailableView {
                Label(search.isEmpty ? "Add your first video" : "No results", systemImage: search.isEmpty ? "film.stack" : "magnifyingglass")
            } description: {
                Text(search.isEmpty ? "Drag MP4 or MOV files here, or click Add Videos." : "Try a different search.")
            } actions: {
                if search.isEmpty { Button("Add Videos…", action: addVideos).buttonStyle(.borderedProminent) }
            }
        default:
            ContentUnavailableView.search(text: search)
        }
    }

    private func addVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose videos to use as wallpapers"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let category = importCategory
        Task { await store.importVideos(urls, category: category) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let category = importCategory
        let group = DispatchGroup()
        let collector = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in await Store.shared.importVideos(collector.urls, category: category) }
        }
        return true
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func add(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

struct TargetPicker: View {
    @Binding var target: String
    @State private var tick = 0

    var body: some View {
        Picker(selection: $target) {
            Text("All Displays").tag(Store.allDisplays)
            if NSScreen.screens.count > 1 {
                Divider()
                ForEach(NSScreen.screens, id: \.key) { screen in
                    Text(screen.localizedName).tag(screen.key)
                }
            }
        } label: {
            Label("Apply to", systemImage: "display")
        }
        .pickerStyle(.menu)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Which display the wallpaper you pick goes on")
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            tick += 1
            if target != Store.allDisplays && !NSScreen.screens.contains(where: { $0.key == target }) {
                target = Store.allDisplays
            }
        }
    }
}

// MARK: - Card

struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let target: String
    @EnvironmentObject var store: Store
    @State private var hovering = false
    @State private var pickingLockFrame = false

    private var inUse: Bool { store.isInUse(wallpaper.id) }
    private var isLockScreen: Bool { store.lockScreen?.wallpaperID == wallpaper.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WallpaperPreview(wallpaper: wallpaper, live: hovering)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(inUse ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: inUse ? 3 : 1)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if inUse { badge("In use", "checkmark.circle.fill") }
                        if isLockScreen { badge("Lock screen", "lock.fill") }
                    }
                    .padding(9)
                }
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 6) {
                        if hovering || wallpaper.favorite {
                            Button { store.toggleFavorite(wallpaper.id) } label: {
                                roundIcon(wallpaper.favorite ? "heart.fill" : "heart",
                                          color: wallpaper.favorite ? .pink : .white)
                            }
                            .buttonStyle(.plain)
                            .help(wallpaper.favorite ? "Remove from favorites" : "Add to favorites")
                        }
                        if hovering {
                            Button { pickingLockFrame = true } label: { roundIcon("lock.rectangle", color: .white) }
                                .buttonStyle(.plain)
                                .help("Choose a frame for your lock screen")
                        }
                    }
                    .padding(9)
                }
                .overlay {
                    if hovering {
                        Button { store.apply(wallpaper, to: target) } label: {
                            Label("Set Wallpaper", systemImage: "photo.on.rectangle")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .shadow(radius: 8)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.12), radius: hovering ? 14 : 6, y: hovering ? 6 : 3)
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.spring(duration: 0.25), value: hovering)

            HStack(spacing: 6) {
                Image(systemName: wallpaper.isScene ? "sparkles" : "film")
                    .font(.caption).foregroundStyle(.secondary)
                Text(wallpaper.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if !wallpaper.category.isEmpty {
                    Text(wallpaper.category)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.apply(wallpaper, to: target) }
        .contextMenu { contextMenu }
        .sheet(isPresented: $pickingLockFrame) {
            LockFramePicker(wallpaper: wallpaper).environmentObject(store)
        }
    }

    private func badge(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func roundIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(.black.opacity(0.4), in: Circle())
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Set on All Displays") { store.apply(wallpaper, to: Store.allDisplays) }
        if NSScreen.screens.count > 1 {
            ForEach(NSScreen.screens, id: \.key) { screen in
                Button("Set on \(screen.localizedName)") { store.apply(wallpaper, to: screen.key) }
            }
        }
        Divider()
        Button(wallpaper.favorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(wallpaper.id) }
        Button("Choose Lock Screen Frame…") { pickingLockFrame = true }
        if isLockScreen {
            Button("Stop Using as Lock Screen") { store.lockScreen = nil }
        }
        Button("Rename…") {
            if let name = promptText(title: "Rename Wallpaper", message: "", initial: wallpaper.title) {
                store.rename(wallpaper.id, to: name)
            }
        }
        Button("Set Category…") {
            if let category = promptText(title: "Set Category",
                                         message: "Type a category name, like Nature or Anime. Leave empty to remove it.",
                                         initial: wallpaper.category) {
                store.setCategory(wallpaper.id, to: category)
            }
        }
        if case .video(let file) = wallpaper.source {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.videoURL(file)]) }
            Divider()
            Button("Delete…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Delete “\(wallpaper.title)”?"
                alert.informativeText = "The video is removed from Livewall's library. The original file you added isn't touched."
                alert.addButton(withTitle: "Delete").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { store.delete(wallpaper) }
            }
        }
    }
}

@MainActor
func promptText(title: String, message: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Previews

/// Fills whatever frame it is given with the wallpaper (still, or animated when `live`).
struct WallpaperPreview: View {
    let wallpaper: Wallpaper
    var live = false
    @EnvironmentObject var store: Store

    var body: some View {
        Color.black
            .overlay {
                switch wallpaper.source {
                case .scene(let kind):
                    if live { LiveScene(kind: kind) } else { SceneCanvas(kind: kind, time: SceneState.startTime) }
                case .video(let file):
                    ZStack {
                        VideoStill(id: wallpaper.id, url: store.videoURL(file))
                        if live { LoopingPlayerView(url: store.videoURL(file)) }
                    }
                }
            }
            .clipped()
    }
}

private struct LiveScene: View {
    let kind: SceneKind
    @StateObject private var state = SceneState()
    var body: some View { SceneView(kind: kind, state: state) }
}

private struct VideoStill: View {
    let id: UUID
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: id) { image = await ThumbnailCache.shared.image(id: id, url: url) }
    }
}

struct LoopingPlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView(frame: .zero)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        context.coordinator.player = player
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.backgroundColor = .clear
        view.layer?.backgroundColor = .clear
        player.play()
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        nsView.playerLayer.player = nil
    }
}

// MARK: - Displays

struct DisplaysView: View {
    @Binding var target: String
    @EnvironmentObject var store: Store
    @State private var tick = 0

    var body: some View {
        let screens = NSScreen.screens
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Click a display to choose where new wallpapers go. Turn a display off to keep its normal desktop.")
                    .foregroundStyle(.secondary)
                ArrangementView(screens: screens, target: $target)
                    .frame(height: 280)
                    .padding(20)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                ForEach(screens, id: \.key) { screen in
                    DisplayRow(screen: screen, selected: target == screen.key) { target = screen.key }
                }
            }
            .padding(24)
        }
        .navigationTitle("Displays")
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in tick += 1 }
    }
}

private struct ArrangementView: View {
    let screens: [NSScreen]
    @Binding var target: String
    @EnvironmentObject var store: Store

    var body: some View {
        GeometryReader { geo in
            let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = min(geo.size.width / max(union.width, 1), geo.size.height / max(union.height, 1))
            let ox = (geo.size.width - union.width * scale) / 2
            let oy = (geo.size.height - union.height * scale) / 2
            ForEach(screens, id: \.key) { screen in
                let f = screen.frame
                let w = f.width * scale, h = f.height * scale
                DisplayTile(screen: screen, selected: target == screen.key || (target == Store.allDisplays))
                    .frame(width: max(w - 8, 10), height: max(h - 8, 10))
                    .position(x: ox + (f.minX - union.minX) * scale + w / 2,
                              y: oy + (union.maxY - f.maxY) * scale + h / 2)
                    .onTapGesture { target = screen.key }
            }
        }
    }
}

private struct DisplayTile: View {
    let screen: NSScreen
    let selected: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        let key = screen.key
        let disabled = store.disabledScreens.contains(key)
        ZStack {
            if let wp = store.wallpaper(forScreen: key), !disabled {
                WallpaperPreview(wallpaper: wp)
            } else {
                Rectangle().fill(.gray.opacity(0.25))
                Text(disabled ? "Off" : "No wallpaper").font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(screen.localizedName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
    }
}

private struct DisplayRow: View {
    let screen: NSScreen
    let selected: Bool
    let select: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        let key = screen.key
        let enabled = Binding(
            get: { !store.disabledScreens.contains(key) },
            set: { on in if on { store.disabledScreens.remove(key) } else { store.disabledScreens.insert(key) } })
        HStack(spacing: 14) {
            Image(systemName: screen == NSScreen.screens.first ? "display" : "display.2")
                .font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.localizedName).font(.headline)
                Text("\(Int(screen.frame.width * screen.backingScaleFactor)) × \(Int(screen.frame.height * screen.backingScaleFactor))  ·  \(store.wallpaper(forScreen: key)?.title ?? "No wallpaper")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(selected ? "Selected" : "Select", action: select).disabled(selected)
            Toggle("Enabled", isOn: enabled).toggleStyle(.switch).labelsHidden()
                .help("Show a live wallpaper on this display")
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var lockEditing: Wallpaper?

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let intervals: [(Int, String)] = [(0, "Never"), (5, "Every 5 minutes"), (15, "Every 15 minutes"),
                                              (30, "Every 30 minutes"), (60, "Every hour"), (360, "Every 6 hours"),
                                              (1440, "Every day")]

    var body: some View {
        let power = PowerInfo.current()
        Form {
            Section("Playback") {
                Toggle("Play sound", isOn: $store.settings.soundOn)
                Slider(value: $store.settings.volume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .disabled(!store.settings.soundOn)
                Picker("Speed", selection: $store.settings.speed) {
                    ForEach(speeds, id: \.self) { s in Text(s == 1 ? "Normal" : "\(s.formatted())×").tag(s) }
                }
                Picker("Video scaling", selection: $store.settings.fillMode) {
                    ForEach(FillMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Auto-change") {
                Picker("Change wallpaper", selection: $store.settings.rotateMinutes) {
                    ForEach(intervals, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Pick from favorites only", isOn: $store.settings.rotateFavoritesOnly)
                    .disabled(store.settings.rotateMinutes == 0)
            }

            Section {
                Toggle("Pause when on battery", isOn: $store.settings.pauseOnBattery)
                Toggle("Pause when battery is low", isOn: $store.settings.pauseOnLowBattery)
                Stepper("Low battery means \(store.settings.lowBatteryLevel)% or less",
                        value: $store.settings.lowBatteryLevel, in: 5...50, step: 5)
                    .disabled(!store.settings.pauseOnLowBattery)
            } header: {
                Text("Battery")
            } footer: {
                if let level = power.level {
                    Text("Battery is at \(level)%\(power.onBattery ? ", running on battery" : ", plugged in").")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Pause when a window covers the desktop", isOn: $store.settings.pauseWhenCovered)
                Toggle("Launch at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
            } header: {
                Text("Behavior")
            } footer: {
                Text("Pausing when covered saves energy while you work in full-screen or maximized apps.")
                    .foregroundStyle(.secondary)
            }

            LockScreenSettings(editing: $lockEditing)

            Section("Library") {
                LabeledContent("Your videos") {
                    Text("\(store.wallpapers.filter { !$0.isScene }.count) · \(ByteCountFormatter.string(fromByteCount: store.librarySize, countStyle: .file))")
                }
                Button("Show Videos Folder") { NSWorkspace.shared.open(store.videosDir) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(item: $lockEditing) { wp in
            LockFramePicker(wallpaper: wp).environmentObject(store)
        }
    }
}
