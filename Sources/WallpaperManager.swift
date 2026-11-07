import AppKit
import AVFoundation
import IOKit.ps
import SwiftUI

/// Owns one desktop-level window per display and decides when each one plays.
@MainActor
final class WallpaperManager {
    private let store: Store
    private var windows: [String: DesktopWindow] = [:]
    private var matched: [String: String] = [:]   // screen -> "wallpaper@time" shown as the macOS picture
    private var screensAsleep = false
    private var applyScheduled = false
    private var lastRotate = Date()
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        store.onChange = { [weak self] in self?.scheduleApply() }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleApply() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                               (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.sessionDidResignActiveNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.didWakeNotification, false),
                               (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.updatePlayback()
                }
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        apply()
    }

    func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyScheduled = false
            self?.apply()
        }
    }

    private func tick() {
        let minutes = store.settings.rotateMinutes
        if minutes > 0, !store.userPaused, Date().timeIntervalSince(lastRotate) >= Double(minutes) * 60 {
            lastRotate = Date()
            store.nextWallpaper()
        }
        updatePlayback()
    }

    /// Create, replace or remove desktop windows so they match the store.
    func apply() {
        let screens = NSScreen.screens
        let primaryKey = screens.first?.key
        var live = Set<String>()

        for screen in screens {
            let key = screen.key
            guard !store.disabledScreens.contains(key), let wp = store.wallpaper(forScreen: key) else {
                updateSystemPicture(for: screen, live: nil)
                continue
            }
            live.insert(key)

            let window: DesktopWindow
            if let existing = windows[key], existing.wallpaper.id == wp.id, existing.wallpaper.source == wp.source {
                window = existing
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            } else {
                windows[key]?.teardown()
                var videoURL: URL?
                if case .video(let file) = wp.source { videoURL = store.videoURL(file) }
                window = DesktopWindow(screen: screen, wallpaper: wp, videoURL: videoURL)
                windows[key] = window
                window.orderFront(nil)
                lastRotate = Date()
            }
            window.configure(settings: store.settings, audible: key == primaryKey)
            updateSystemPicture(for: screen, live: wp)
        }

        for (key, window) in windows where !live.contains(key) {
            window.teardown()
            windows[key] = nil
        }
        updatePlayback()
    }

    func updatePlayback() {
        let s = store.settings
        let power = PowerInfo.current()
        var powerReason: String?
        if power.onBattery {
            if let level = power.level, s.pauseOnLowBattery, level <= s.lowBatteryLevel {
                powerReason = "Paused — low battery"
            } else if s.pauseOnBattery {
                powerReason = "Paused — on battery"
            }
        }
        let covered = s.pauseWhenCovered ? Occlusion.coveredScreens() : []

        var playingCount = 0
        for (key, window) in windows {
            let play = !store.userPaused && !screensAsleep && powerReason == nil && !covered.contains(key)
            window.setPlaying(play)
            if play { playingCount += 1 }
        }

        let status: String
        if windows.isEmpty { status = "No wallpaper set" }
        else if store.userPaused { status = "Paused" }
        else if screensAsleep { status = "Paused — display asleep" }
        else if let powerReason { status = powerReason }
        else if playingCount == 0 { status = "Paused — desktop is covered" }
        else { status = playingCount == 1 ? "Playing" : "Playing on \(playingCount) displays" }
        if store.status != status { store.status = status }
    }

    // MARK: System desktop picture

    /// macOS shows the desktop picture on the lock screen, in Mission Control and after Livewall quits.
    /// Use the frame the user picked for the lock screen, or else the live wallpaper's first frame.
    private func updateSystemPicture(for screen: NSScreen, live: Wallpaper?) {
        let key = screen.key
        var want: (Wallpaper, Double)?
        if let lock = store.lockScreen, let wp = store.wallpaper(id: lock.wallpaperID) {
            want = (wp, lock.time)
        } else if store.settings.matchSystemWallpaper, let live {
            want = (live, 0)
        }
        guard let (wp, time) = want else {
            restoreOriginal(for: screen)
            return
        }
        let signature = "\(wp.id.uuidString)@\(time)"
        guard matched[key] != signature else { return }
        matched[key] = signature

        if store.originalDesktops[key] == nil,
           let current = NSWorkspace.shared.desktopImageURL(for: screen),
           !current.path.hasPrefix(store.framesDir.path) {
            store.originalDesktops[key] = current
        }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        Task { @MainActor in
            guard let url = await store.stillImage(for: wp, at: time, pointSize: size, scale: scale),
                  matched[key] == signature else { return }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
        }
    }

    private func restoreOriginal(for screen: NSScreen) {
        let key = screen.key
        matched[key] = nil
        guard let original = store.originalDesktops[key] else { return }
        try? NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: [:])
        store.originalDesktops[key] = nil
    }
}

// MARK: - Desktop window

@MainActor
final class DesktopWindow: NSWindow {
    let wallpaper: Wallpaper
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerView: PlayerView?
    private let sceneState = SceneState()
    private var playing = false
    private var speed: Float = 1

    init(screen: NSScreen, wallpaper: Wallpaper, videoURL: URL?) {
        self.wallpaper = wallpaper
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none

        if let videoURL {
            let view = PlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.allowsExternalPlayback = false
            queue.preventsDisplaySleepDuringVideoPlayback = false   // let the Mac sleep normally
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: videoURL))
            view.playerLayer.player = queue
            player = queue
            playerView = view
            contentView = view
        } else if case .scene(let kind) = wallpaper.source {
            sceneState.paused = true
            contentView = NSHostingView(rootView: SceneView(kind: kind, state: sceneState))
        }
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(settings: AppSettings, audible: Bool) {
        speed = Float(settings.speed)
        sceneState.speed = settings.speed
        guard let player else { return }
        playerView?.playerLayer.videoGravity = settings.fillMode.gravity
        player.volume = Float(settings.volume)
        player.isMuted = !(settings.soundOn && audible)
        if playing && player.rate != speed { player.rate = speed }
    }

    func setPlaying(_ play: Bool) {
        guard play != playing else { return }
        playing = play
        sceneState.paused = !play
        guard let player else { return }
        if play { player.rate = speed } else { player.pause() }
    }

    func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        sceneState.paused = true
        orderOut(nil)
        close()
    }
}

final class PlayerView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

// MARK: - Power and occlusion

struct PowerInfo {
    var onBattery: Bool
    var level: Int?

    static func current() -> PowerInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerInfo(onBattery: false, level: nil)
        }
        let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var level: Int?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      let current = desc["Current Capacity"] as? Int,
                      let max = desc["Max Capacity"] as? Int, max > 0 else { continue }
                level = current * 100 / max
            }
        }
        return PowerInfo(onBattery: source == "Battery Power", level: level)
    }
}

enum Occlusion {
    /// Screens whose desktop is almost entirely hidden by another app's window (including full-screen apps).
    @MainActor
    static func coveredScreens() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = Int(getpid())
        let windows: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != me,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.9,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var covered = Set<String>()
        for screen in NSScreen.screens {
            let v = screen.visibleFrame
            // Convert from AppKit (bottom-left origin) to window-server (top-left origin) coordinates.
            let target = CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
            let area = target.width * target.height
            if windows.contains(where: { let i = $0.intersection(target); return !i.isNull && i.width * i.height >= area * 0.92 }) {
                covered.insert(screen.key)
            }
        }
        return covered
    }
}
