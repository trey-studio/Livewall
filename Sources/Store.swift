import AppKit
import AVFoundation
import SwiftUI

// MARK: - Model

enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case aurora, warp, bubbles, waves, lava
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .warp: "Warp Speed"
        case .bubbles: "Deep Blue"
        case .waves: "Sunset Waves"
        case .lava: "Lava Lamp"
        }
    }
}

enum WallpaperSource: Codable, Hashable {
    case video(fileName: String)
    case scene(SceneKind)
}

struct Wallpaper: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var source: WallpaperSource
    var favorite = false
    var category = ""
    var added = Date()

    var isScene: Bool { if case .scene = source { return true }; return false }
}

/// A single moment of a wallpaper, used as the lock screen picture.
struct LockFrame: Codable, Equatable {
    var wallpaperID: UUID
    var time: Double
}

enum FillMode: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: "Fill screen"
        case .fit: "Fit (show whole video)"
        case .stretch: "Stretch"
        }
    }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}

struct AppSettings: Codable, Equatable {
    var soundOn = false
    var volume = 0.6
    var speed = 1.0
    var fillMode: FillMode = .fill
    var pauseOnBattery = false
    var pauseOnLowBattery = true
    var lowBatteryLevel = 20
    var pauseWhenCovered = true
    var matchSystemWallpaper = true
    var rotateMinutes = 0
    var rotateFavoritesOnly = true

    init() {}

    // Tolerates missing keys so older saved settings keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        soundOn = try c.decodeIfPresent(Bool.self, forKey: .soundOn) ?? d.soundOn
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        fillMode = try c.decodeIfPresent(FillMode.self, forKey: .fillMode) ?? d.fillMode
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? d.pauseOnBattery
        pauseOnLowBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowBattery) ?? d.pauseOnLowBattery
        lowBatteryLevel = try c.decodeIfPresent(Int.self, forKey: .lowBatteryLevel) ?? d.lowBatteryLevel
        pauseWhenCovered = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenCovered) ?? d.pauseWhenCovered
        matchSystemWallpaper = try c.decodeIfPresent(Bool.self, forKey: .matchSystemWallpaper) ?? d.matchSystemWallpaper
        rotateMinutes = try c.decodeIfPresent(Int.self, forKey: .rotateMinutes) ?? d.rotateMinutes
        rotateFavoritesOnly = try c.decodeIfPresent(Bool.self, forKey: .rotateFavoritesOnly) ?? d.rotateFavoritesOnly
    }
}

enum SidebarItem: Hashable {
    case all, favorites, scenes, videos, category(String), displays, settings
    var title: String {
        switch self {
        case .all: "All Wallpapers"
        case .favorites: "Favorites"
        case .scenes: "Animated Scenes"
        case .videos: "My Videos"
        case .category(let c): c
        case .displays: "Displays"
        case .settings: "Settings"
        }
    }
}

private struct SavedState: Codable {
    var wallpapers: [Wallpaper]
    var assignments: [String: UUID]
    var disabledScreens: Set<String>
    var settings: AppSettings
    var originalDesktops: [String: URL]
    var hasLaunchedBefore: Bool
    var lockScreen: LockFrame?
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    /// Stable identifier that survives reboots and replugging.
    var key: String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(displayID)"
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let allDisplays = "all"

    @Published var wallpapers: [Wallpaper] = [] { didSet { persist(); changed() } }
    /// Screen key (or "all") -> wallpaper id.
    @Published var assignments: [String: UUID] = [:] { didSet { persist(); changed() } }
    @Published var disabledScreens: Set<String> = [] { didSet { persist(); changed() } }
    @Published var settings = AppSettings() { didSet { persist(); changed() } }
    @Published var userPaused = false { didSet { changed() } }
    @Published var status = "Starting…"
    @Published var alertMessage: String?
    @Published var requestedPage: SidebarItem?
    /// A frame the user picked for the lock screen. When nil, the live wallpaper's first frame is used.
    @Published var lockScreen: LockFrame? { didSet { persist(); changed() } }

    var originalDesktops: [String: URL] = [:] { didSet { persist() } }
    var hasLaunchedBefore = false { didSet { persist() } }
    var onChange: (() -> Void)?

    let root: URL
    let videosDir: URL
    let framesDir: URL
    private var loading = true

    private init() {
        let fm = FileManager.default
        root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Livewall", isDirectory: true)
        videosDir = root.appendingPathComponent("Videos", isDirectory: true)
        framesDir = root.appendingPathComponent("Stills", isDirectory: true)
        for dir in [root, videosDir, framesDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
        // Make sure every built-in scene is in the library.
        for kind in SceneKind.allCases where !wallpapers.contains(where: { $0.source == .scene(kind) }) {
            wallpapers.append(Wallpaper(title: kind.title, source: .scene(kind)))
        }
        loading = false
        persist()
    }

    private var stateURL: URL { root.appendingPathComponent("library.json") }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        wallpapers = s.wallpapers
        assignments = s.assignments
        disabledScreens = s.disabledScreens
        settings = s.settings
        originalDesktops = s.originalDesktops
        hasLaunchedBefore = s.hasLaunchedBefore
        lockScreen = s.lockScreen
    }

    private func persist() {
        guard !loading else { return }
        let s = SavedState(wallpapers: wallpapers, assignments: assignments, disabledScreens: disabledScreens,
                           settings: settings, originalDesktops: originalDesktops, hasLaunchedBefore: hasLaunchedBefore,
                           lockScreen: lockScreen)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func changed() {
        guard !loading else { return }
        onChange?()
    }

    // MARK: Queries

    var categories: [String] {
        Array(Set(wallpapers.map(\.category).filter { !$0.isEmpty })).sorted()
    }

    func videoURL(_ fileName: String) -> URL { videosDir.appendingPathComponent(fileName) }

    func wallpaper(id: UUID?) -> Wallpaper? {
        guard let id else { return nil }
        return wallpapers.first { $0.id == id }
    }

    func wallpaper(forScreen key: String) -> Wallpaper? {
        wallpaper(id: assignments[key] ?? assignments[Store.allDisplays])
    }

    func isInUse(_ id: UUID) -> Bool {
        NSScreen.screens.contains { !disabledScreens.contains($0.key) && wallpaper(forScreen: $0.key)?.id == id }
    }

    // MARK: Actions

    func apply(_ wp: Wallpaper, to target: String) {
        if target == Store.allDisplays {
            assignments = [Store.allDisplays: wp.id]
        } else {
            assignments[target] = wp.id
        }
    }

    func nextWallpaper() {
        var pool = settings.rotateFavoritesOnly ? wallpapers.filter(\.favorite) : wallpapers
        if pool.count < 2 { pool = wallpapers }
        let current = assignments[Store.allDisplays] ?? assignments.values.first
        guard let pick = pool.filter({ $0.id != current }).randomElement() ?? pool.first else { return }
        apply(pick, to: Store.allDisplays)
    }

    func removeAllWallpapers() { assignments = [:] }

    func toggleFavorite(_ id: UUID) {
        guard let i = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[i].favorite.toggle()
    }

    func rename(_ id: UUID, to title: String) {
        guard !title.isEmpty, let i = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[i].title = title
    }

    func setCategory(_ id: UUID, to category: String) {
        guard let i = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[i].category = category
    }

    func delete(_ wp: Wallpaper) {
        if case .video(let file) = wp.source {
            try? FileManager.default.removeItem(at: videoURL(file))
        }
        if let stills = try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil) {
            for url in stills where url.lastPathComponent.hasPrefix(wp.id.uuidString) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        ThumbnailCache.shared.remove(wp.id)
        if lockScreen?.wallpaperID == wp.id { lockScreen = nil }
        assignments = assignments.filter { $0.value != wp.id }
        wallpapers.removeAll { $0.id == wp.id }
    }

    func importVideos(_ urls: [URL], category: String = "") async {
        var skipped: [String] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard playable, !tracks.isEmpty else { skipped.append(url.lastPathComponent); continue }

            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
            let name = UUID().uuidString + "." + ext
            let dest = videoURL(name)
            let copied = await Task.detached { (try? FileManager.default.copyItem(at: url, to: dest)) != nil }.value
            guard copied else { skipped.append(url.lastPathComponent); continue }

            let title = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            wallpapers.append(Wallpaper(title: title, source: .video(fileName: name), category: category))
        }
        if !skipped.isEmpty {
            alertMessage = "Couldn't add \(skipped.count) file(s). Livewall plays videos macOS supports, like MP4, MOV and M4V.\n\n"
                + skipped.joined(separator: "\n")
        }
    }

    /// A still image of the wallpaper at `time` seconds, sized for a screen, saved as PNG
    /// for use as the macOS desktop picture (which macOS also shows on the lock screen).
    func stillImage(for wp: Wallpaper, at time: Double = 0, pointSize: CGSize, scale: CGFloat) async -> URL? {
        let px = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let ms = Int((time * 1000).rounded())
        let url = framesDir.appendingPathComponent("\(wp.id.uuidString)-t\(ms)-\(Int(px.width))x\(Int(px.height)).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var image: CGImage?
        switch wp.source {
        case .video(let file):
            image = await MediaTools.frame(url: videoURL(file), maxSize: px, at: time, exact: true)
        case .scene(let kind):
            let renderer = ImageRenderer(content: SceneCanvas(kind: kind, time: SceneState.startTime + time)
                .frame(width: pointSize.width, height: pointSize.height))
            renderer.scale = scale
            image = renderer.cgImage
        }
        guard let image, MediaTools.writePNG(image, to: url) else { return nil }
        return url
    }

    var librarySize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - Media helpers

enum MediaTools {
    static func frame(url: URL, maxSize: CGSize, at seconds: Double, exact: Bool = false) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        if exact {
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
        }
        for t in [seconds, 0] {
            if let result = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                return result.image
            }
        }
        return nil
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [UUID: NSImage] = [:]

    func image(id: UUID, url: URL) async -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let cg = await MediaTools.frame(url: url, maxSize: CGSize(width: 720, height: 450), at: 1) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[id] = img
        return img
    }

    func remove(_ id: UUID) { cache[id] = nil }
}
