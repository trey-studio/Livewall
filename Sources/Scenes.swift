import SwiftUI

/// Playback state shared between a desktop window and its animated scene.
final class SceneState: ObservableObject {
    static let startTime = 42.0
    @Published var paused = false
    var speed = 1.0
    private var elapsed = 0.0
    private var last: Date?

    /// Scene time that only advances while playing, so resuming never jumps.
    func time(at date: Date) -> Double {
        if let last { elapsed += min(max(date.timeIntervalSince(last), 0), 0.1) * speed }
        last = date
        return SceneState.startTime + elapsed
    }
}

struct SceneView: View {
    let kind: SceneKind
    @ObservedObject var state: SceneState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: state.paused)) { context in
            SceneCanvas(kind: kind, time: state.time(at: context.date))
        }
        .ignoresSafeArea()
    }
}

struct SceneCanvas: View {
    let kind: SceneKind
    let time: Double

    var body: some View {
        Canvas(opaque: true) { ctx, size in
            switch kind {
            case .aurora: Scenes.aurora(&ctx, size, time)
            case .warp: Scenes.warp(&ctx, size, time)
            case .bubbles: Scenes.bubbles(&ctx, size, time)
            case .waves: Scenes.waves(&ctx, size, time)
            case .lava: Scenes.lava(&ctx, size, time)
            }
        }
        .drawingGroup()
    }
}

private typealias RGB = (Double, Double, Double)

enum Scenes {
    /// Deterministic pseudo-random number in 0..<1.
    static func h(_ x: Double) -> Double {
        let v = sin(x * 127.1 + 311.7) * 43758.5453
        return v - v.rounded(.down)
    }

    private static func color(_ c: RGB, _ opacity: Double = 1) -> Color {
        Color(red: c.0, green: c.1, blue: c.2).opacity(opacity)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> Color {
        Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // MARK: Aurora

    static func aurora(_ c: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        c.fill(Path(CGRect(origin: .zero, size: s)), with: .linearGradient(
            Gradient(colors: [color((0.01, 0.02, 0.07)), color((0.03, 0.05, 0.14))]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))

        let palette: [RGB] = [(0.10, 0.95, 0.70), (0.20, 0.55, 1.00), (0.65, 0.30, 1.00),
                              (1.00, 0.35, 0.65), (0.15, 0.85, 0.95), (0.45, 1.00, 0.45)]
        let m = max(s.width, s.height)

        c.blendMode = .screen
        for (i, col) in palette.enumerated() {
            let f = Double(i)
            let x = s.width * (0.5 + 0.42 * sin(t * (0.050 + 0.011 * f) + f * 1.9))
            let y = s.height * (0.5 + 0.36 * cos(t * (0.041 + 0.009 * f) + f * 2.7))
            let r = m * (0.30 + 0.08 * sin(t * 0.13 + f * 1.3))
            c.fill(circle(x, y, r), with: .radialGradient(
                Gradient(colors: [color(col, 0.5), color(col, 0)]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }

        // Curtains of light.
        for i in 0..<3 {
            let f = Double(i)
            let baseY = s.height * (0.22 + 0.13 * f)
            let steps = 80
            var top: [CGPoint] = []
            for k in 0...steps {
                let x = s.width * Double(k) / Double(steps)
                let u = x / s.width
                let y = baseY + sin(u * 6 + t * 0.30 + f * 2) * s.height * 0.06
                    + sin(u * 13 - t * 0.45 + f) * s.height * 0.02
                top.append(CGPoint(x: x, y: y))
            }
            var p = Path()
            p.move(to: top[0])
            for pt in top.dropFirst() { p.addLine(to: pt) }
            for pt in top.reversed() { p.addLine(to: CGPoint(x: pt.x, y: pt.y + s.height * 0.24)) }
            p.closeSubpath()
            let col = palette[[0, 4, 2][i]]
            c.fill(p, with: .linearGradient(
                Gradient(colors: [color(col, 0), color(col, 0.28), color(col, 0)]),
                startPoint: CGPoint(x: 0, y: baseY - s.height * 0.06),
                endPoint: CGPoint(x: 0, y: baseY + s.height * 0.26)))
        }

        c.blendMode = .normal
        for i in 0..<160 {
            let f = Double(i)
            let x = h(f) * s.width, y = h(f + 50) * s.height * 0.75
            let twinkle = 0.3 + 0.7 * (0.5 + 0.5 * sin(t * (1 + h(f + 7)) + f))
            c.fill(circle(x, y, 0.6 + h(f + 9) * 1.2), with: .color(.white.opacity(0.55 * twinkle)))
        }
    }

    // MARK: Warp

    static func warp(_ c: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let cx = s.width / 2 + sin(t * 0.10) * s.width * 0.04
        let cy = s.height / 2 + cos(t * 0.13) * s.height * 0.04
        c.fill(Path(CGRect(origin: .zero, size: s)), with: .radialGradient(
            Gradient(colors: [color((0.10, 0.06, 0.25)), color((0.02, 0.01, 0.06)), .black]),
            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: max(s.width, s.height) * 0.7))

        let maxR = hypot(s.width, s.height) * 0.6
        let unit = min(s.width, s.height) / 900
        for i in 0..<650 {
            let f = Double(i)
            let angle = h(f) * .pi * 2
            let speed = 0.05 + h(f + 1.3) * 0.10
            let phase = (h(f + 2.7) + t * speed).truncatingRemainder(dividingBy: 1)
            let d = 6 * unit + phase * phase * phase * maxR
            let d0 = d * (1 - 0.08 * phase)
            var path = Path()
            path.move(to: CGPoint(x: cx + cos(angle) * d0, y: cy + sin(angle) * d0))
            path.addLine(to: CGPoint(x: cx + cos(angle) * d, y: cy + sin(angle) * d))
            let tint = h(f + 4.1)
            let col: Color = tint < 0.15 ? color((0.6, 0.8, 1)) : tint > 0.9 ? color((1, 0.75, 0.9)) : .white
            c.stroke(path, with: .color(col.opacity(min(1, phase * 1.8))),
                     style: StrokeStyle(lineWidth: (0.5 + phase * 2.8) * unit, lineCap: .round))
        }
    }

    // MARK: Bubbles

    static func bubbles(_ c: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        c.fill(Path(CGRect(origin: .zero, size: s)), with: .linearGradient(
            Gradient(colors: [color((0.05, 0.47, 0.64)), color((0.02, 0.18, 0.38)), color((0.01, 0.04, 0.14))]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))

        c.blendMode = .screen
        for i in 0..<6 {
            let f = Double(i)
            let x = s.width * (0.08 + 0.17 * f) + sin(t * 0.2 + f) * s.width * 0.03
            let w = s.width * (0.04 + 0.03 * h(f))
            var p = Path()
            p.move(to: CGPoint(x: x - w * 0.5, y: 0))
            p.addLine(to: CGPoint(x: x + w * 0.5, y: 0))
            p.addLine(to: CGPoint(x: x + w * 2.2 + s.width * 0.08, y: s.height))
            p.addLine(to: CGPoint(x: x - w * 0.2 + s.width * 0.08, y: s.height))
            p.closeSubpath()
            let a = 0.07 + 0.05 * sin(t * 0.5 + f * 1.7)
            c.fill(p, with: .linearGradient(Gradient(colors: [.white.opacity(a), .white.opacity(0)]),
                                            startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height * 0.85)))
        }

        c.blendMode = .normal
        let unit = min(s.width, s.height) / 900
        for i in 0..<90 {
            let f = Double(i)
            let r = (4 + pow(h(f + 3), 2) * 30) * unit
            let speed = (25 + h(f + 1) * 60) * unit * (0.6 + r / (34 * unit) * 0.6)
            let span = s.height + 4 * r
            let y = s.height + 2 * r - (h(f + 2) * span + t * speed).truncatingRemainder(dividingBy: span)
            let x = h(f) * s.width + sin(t * (0.6 + h(f + 5)) + f) * 14 * unit
            let bubble = circle(x, y, r)
            c.fill(bubble, with: .radialGradient(Gradient(colors: [.white.opacity(0.02), .white.opacity(0.12)]),
                                                 center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            c.stroke(bubble, with: .color(.white.opacity(0.35)), lineWidth: max(0.8, r * 0.08))
            let hr = r * 0.28
            c.fill(Path(ellipseIn: CGRect(x: x - r * 0.45 - hr / 2, y: y - r * 0.5 - hr / 2, width: hr, height: hr * 0.8)),
                   with: .color(.white.opacity(0.55)))
        }
    }

    // MARK: Waves

    static func waves(_ c: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let horizon = s.height * 0.58
        c.fill(Path(CGRect(x: 0, y: 0, width: s.width, height: horizon + 2)), with: .linearGradient(
            Gradient(stops: [.init(color: color((0.16, 0.08, 0.32)), location: 0),
                             .init(color: color((0.75, 0.25, 0.45)), location: 0.6),
                             .init(color: color((1.0, 0.62, 0.35)), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))

        let sunR = min(s.width, s.height) * 0.12
        let sunX = s.width * 0.5
        let sunY = horizon - sunR * 0.35 + sin(t * 0.05) * sunR * 0.08
        c.fill(circle(sunX, sunY, sunR * 4), with: .radialGradient(
            Gradient(colors: [color((1, 0.8, 0.45), 0.45), color((1, 0.6, 0.4), 0)]),
            center: CGPoint(x: sunX, y: sunY), startRadius: 0, endRadius: sunR * 4))
        c.fill(circle(sunX, sunY, sunR), with: .linearGradient(
            Gradient(colors: [color((1, 0.96, 0.65)), color((1, 0.55, 0.3))]),
            startPoint: CGPoint(x: 0, y: sunY - sunR), endPoint: CGPoint(x: 0, y: sunY + sunR)))

        c.fill(Path(CGRect(x: 0, y: horizon, width: s.width, height: s.height - horizon)), with: .linearGradient(
            Gradient(colors: [color((0.42, 0.16, 0.40)), color((0.05, 0.03, 0.15))]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: s.height)))

        // Sun glitter on the water.
        for k in 0..<30 {
            let f = Double(k)
            let y = horizon + 3 + f * (s.height - horizon) * 0.028
            let w = sunR * (1.7 - f * 0.04) * (0.6 + 0.4 * sin(t * 2 + f * 1.3))
            let x = sunX + sin(t * 1.3 + f) * sunR * 0.12
            c.fill(Path(CGRect(x: x - w / 2, y: y, width: w, height: 1.5 + f * 0.25)),
                   with: .color(color((1, 0.85, 0.55), max(0, 0.55 - f * 0.017))))
        }

        let layers = 6
        let far: RGB = (0.45, 0.18, 0.44), near: RGB = (0.06, 0.03, 0.16)
        for i in 0..<layers {
            let f = Double(i)
            let depth = f / Double(layers - 1)
            let base = horizon + (s.height - horizon) * (0.10 + 0.82 * pow(depth, 1.3))
            let amp = s.height * (0.005 + 0.028 * depth)
            let freq = (2.0 + (1 - depth) * 6) * .pi * 2 / s.width
            let step = max(4, s.width / 160)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: s.height))
            var x = 0.0
            while x <= s.width + step {
                let y = base + sin(x * freq + t * (0.5 + depth * 0.6) + f * 1.7) * amp
                    + sin(x * freq * 2.3 - t * (0.8 + depth) + f) * amp * 0.35
                p.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            p.addLine(to: CGPoint(x: s.width, y: s.height))
            p.closeSubpath()
            c.fill(p, with: .color(mix(far, near, depth)))
        }
    }

    // MARK: Lava lamp

    static func lava(_ c: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        c.fill(Path(CGRect(origin: .zero, size: s)), with: .linearGradient(
            Gradient(colors: [color((0.10, 0.02, 0.12)), color((0.28, 0.04, 0.14))]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))
        let m = min(s.width, s.height)

        c.fill(circle(s.width / 2, s.height, max(s.width, s.height) * 0.6), with: .radialGradient(
            Gradient(colors: [color((1, 0.4, 0.2), 0.25), color((1, 0.3, 0.3), 0)]),
            center: CGPoint(x: s.width / 2, y: s.height), startRadius: 0, endRadius: max(s.width, s.height) * 0.6))

        let tints: [RGB] = [(1.0, 0.45, 0.18), (1.0, 0.2, 0.5)]
        for (layer, tint) in tints.enumerated() {
            c.drawLayer { outer in
                outer.addFilter(.alphaThreshold(min: 0.5, color: color(tint)))
                outer.addFilter(.blur(radius: m * 0.035))
                outer.drawLayer { l in
                    for i in 0..<8 {
                        let f = Double(i) + Double(layer) * 20
                        let r = m * (0.06 + 0.08 * h(f + 2))
                        let x = s.width * (0.12 + 0.76 * h(f)) + sin(t * 0.13 + f) * s.width * 0.05
                        let y = s.height * 0.5 + sin(t * (0.04 + 0.05 * h(f + 1)) + f * 2.1) * (s.height * 0.5 + r * 0.3)
                        l.fill(circle(x, y, r), with: .color(.white))
                    }
                    if layer == 0 {
                        l.fill(Path(ellipseIn: CGRect(x: -s.width * 0.1, y: s.height * 0.93, width: s.width * 1.2, height: s.height * 0.25)),
                               with: .color(.white))
                    } else {
                        l.fill(Path(ellipseIn: CGRect(x: -s.width * 0.1, y: -s.height * 0.18, width: s.width * 1.2, height: s.height * 0.25)),
                               with: .color(.white))
                    }
                }
            }
        }
    }
}
