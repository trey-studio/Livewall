import AppKit
import AVFoundation
import SwiftUI

func timecode(_ t: Double) -> String {
    let minutes = Int(t) / 60
    return String(format: "%d:%04.1f", minutes, t - Double(minutes * 60))
}

// MARK: - Scrubbing

/// Moves through a video (or an animated scene) so the user can stop on one frame.
@MainActor
final class FrameScrubber: ObservableObject {
    @Published var time = 0.0
    @Published private(set) var duration = 60.0
    @Published private(set) var isPlaying = false
    private(set) var frameStep = 1.0 / 30
    let player: AVPlayer?
    private var observer: Any?
    private var timer: Timer?

    init(videoURL: URL?, startAt: Double) {
        if let videoURL {
            let p = AVPlayer(url: videoURL)
            p.isMuted = true
            p.actionAtItemEnd = .pause
            p.preventsDisplaySleepDuringVideoPlayback = false
            player = p
        } else {
            player = nil
        }
        time = startAt
    }

    func load() async {
        guard let player, let asset = player.currentItem?.asset else { return }
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { duration = d.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            frameStep = 1 / Double(fps)
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.time = min(t.seconds, self.duration)
                if player.rate == 0 { self.isPlaying = false }
            }
        }
        seek(time)
    }

    func seek(_ t: Double) {
        time = min(max(t, 0), max(duration - frameStep, 0))
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ frames: Int) {
        pause()
        seek(time + Double(frames) * frameStep)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        isPlaying = true
        if let player {
            if time >= duration - frameStep * 2 { seek(0) }
            player.play()
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.time = (self.time + 1.0 / 30).truncatingRemainder(dividingBy: self.duration)
                }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        timer?.invalidate()
        timer = nil
        if let player {
            player.pause()
            let t = player.currentTime().seconds
            if t.isFinite { time = min(max(t, 0), duration) }
        }
    }

    func stop() {
        pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
    }
}

private struct PlayerHost: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView(frame: .zero)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}

// MARK: - Picker

struct LockFramePicker: View {
    let wallpaper: Wallpaper
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scrubber: FrameScrubber
    @State private var showClock = true

    init(wallpaper: Wallpaper) {
        self.wallpaper = wallpaper
        var url: URL?
        if case .video(let file) = wallpaper.source { url = Store.shared.videoURL(file) }
        let start = Store.shared.lockScreen?.wallpaperID == wallpaper.id ? Store.shared.lockScreen?.time ?? 0 : 0
        _scrubber = StateObject(wrappedValue: FrameScrubber(videoURL: url, startAt: start))
    }

    private var screenAspect: CGFloat {
        guard let f = NSScreen.screens.first?.frame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    private var isCurrentLock: Bool { store.lockScreen?.wallpaperID == wallpaper.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a Lock Screen Frame").font(.title2.weight(.bold))
                Text("Play or drag through “\(wallpaper.title)” and stop on the moment you want.")
                    .foregroundStyle(.secondary)
            }

            preview
                .aspectRatio(screenAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

            HStack(spacing: 10) {
                Button { scrubber.togglePlay() } label: {
                    Image(systemName: scrubber.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(scrubber.isPlaying ? "Pause" : "Play")

                Button { scrubber.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Back one frame (←)")

                Slider(value: Binding(get: { scrubber.time }, set: { scrubber.pause(); scrubber.seek($0) }),
                       in: 0...max(scrubber.duration, 0.1))

                Button { scrubber.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Forward one frame (→)")

                Text("\(timecode(scrubber.time)) / \(timecode(scrubber.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 96, alignment: .trailing)
            }

            Toggle("Show the lock screen clock in the preview", isOn: $showClock)
                .toggleStyle(.checkbox)

            Text("macOS shows your desktop picture on the lock screen, so Livewall sets this frame as your Mac's wallpaper. Your live wallpaper keeps playing on top of it while you're logged in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if isCurrentLock {
                    Button("Stop Using This Frame", role: .destructive) {
                        store.lockScreen = nil
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use as Lock Screen") {
                    scrubber.pause()
                    store.lockScreen = LockFrame(wallpaperID: wallpaper.id, time: scrubber.time)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720)
        .task { await scrubber.load() }
        .onDisappear { scrubber.stop() }
    }

    @ViewBuilder private var preview: some View {
        Color.black
            .overlay {
                switch wallpaper.source {
                case .scene(let kind):
                    SceneCanvas(kind: kind, time: SceneState.startTime + scrubber.time)
                case .video:
                    if let player = scrubber.player { PlayerHost(player: player) }
                }
            }
            .overlay(alignment: .top) {
                if showClock { LockClock() }
            }
            .clipped()
    }
}

/// A rough stand-in for the macOS lock screen clock, so the user can see how the frame looks behind it.
private struct LockClock: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: h * 0.005) {
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: h * 0.04, weight: .semibold))
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: h * 0.19, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .frame(maxWidth: .infinity)
            .padding(.top, h * 0.07)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Settings section and thumbnail

/// One exact frame of a wallpaper, as a small picture.
struct FrameThumb: View {
    let wallpaper: Wallpaper
    let time: Double
    @EnvironmentObject var store: Store
    @State private var image: NSImage?

    var body: some View {
        Color.black
            .overlay {
                switch wallpaper.source {
                case .scene(let kind):
                    SceneCanvas(kind: kind, time: SceneState.startTime + time)
                case .video:
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                }
            }
            .clipped()
            .task(id: "\(wallpaper.id)@\(time)") {
                guard case .video(let file) = wallpaper.source,
                      let cg = await MediaTools.frame(url: store.videoURL(file), maxSize: CGSize(width: 480, height: 300),
                                                      at: time, exact: true) else { return }
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
    }
}

struct LockScreenSettings: View {
    @EnvironmentObject var store: Store
    @Binding var editing: Wallpaper?

    var body: some View {
        Section {
            if let lock = store.lockScreen, let wp = store.wallpaper(id: lock.wallpaperID) {
                HStack(spacing: 12) {
                    FrameThumb(wallpaper: wp, time: lock.time)
                        .frame(width: 112, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wp.title).font(.headline)
                        Text("Frame at \(timecode(lock.time))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change…") { editing = wp }
                    Button("Remove") { store.lockScreen = nil }
                }
            } else {
                LabeledContent("Lock screen picture") {
                    Text(store.settings.matchSystemWallpaper ? "First frame of your live wallpaper" : "Your normal macOS wallpaper")
                        .foregroundStyle(.secondary)
                }
                Button("Choose a Frame…") {
                    editing = store.wallpaper(forScreen: NSScreen.screens.first?.key ?? "") ?? store.wallpapers.first
                }
                .disabled(store.wallpapers.isEmpty)
            }
            Toggle("Use the live wallpaper's first frame when no frame is chosen",
                   isOn: $store.settings.matchSystemWallpaper)
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("macOS shows your desktop picture on the lock screen, so Livewall sets the frame as your Mac's wallpaper. You can also right-click any wallpaper and choose “Choose Lock Screen Frame…”.")
                .foregroundStyle(.secondary)
        }
    }
}
