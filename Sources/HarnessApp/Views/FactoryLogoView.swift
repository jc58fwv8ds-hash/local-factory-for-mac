import SwiftUI

/// The Local Factory logo (2026-10-08): a one-gray pixel-art factory (three sawtooth roofs, the last one in front of a plain chimney) with orange-yellow
/// windows and smoke from the chimney.
/// While the app works, the smoke puffs rise and drift in steps (8 frames a second, so it stays pixel-like).
struct FactoryLogoView: View {
    var isWorking = false
    var height: CGFloat = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: !isWorking)) { timeline in
            Canvas { context, size in
                let pixel = size.height / CGFloat(FactoryLogo.height)
                let time = isWorking ? timeline.date.timeIntervalSinceReferenceDate : nil
                for dot in FactoryLogo.dots(at: time) {
                    let rect = CGRect(x: CGFloat(dot.x) * pixel, y: CGFloat(dot.y) * pixel, width: pixel, height: pixel)
                    context.fill(Path(rect.insetBy(dx: -0.01, dy: -0.01)), with: .color(dot.color.opacity(dot.opacity)))
                }
            }
        }
        .frame(width: height * CGFloat(FactoryLogo.width) / CGFloat(FactoryLogo.height), height: height)
        .accessibilityLabel(isWorking ? "Local Factory(処理中)" : "Local Factory")
    }
}

enum FactoryLogo {
    static let width = 24
    static let height = 31
    /// Rows below the smoke area; the factory occupies rows 8...30.
    static let smokeRows = 8

    /// K outline, G gray (the whole building is one gray), W window, Y window highlight.
    static let factory = [
        "..................KKKK..",
        "..................KGGK..",
        "..................KGGK..",
        "..................KGGK..",
        ".K......K......K..KGGK..",
        ".KK.....KK.....KK.KGGK..",
        ".KGK....KGK....KGKKGGK..",
        ".KGGK...KGGK...KGGKGGK..",
        ".KGGGK..KGGGK..KGGGKGK..",
        ".KGGGGK.KGGGGK.KGGGGKK..",
        ".KGGGGGKKGGGGGKKGGGGGK..",
        ".KKKKKKKKKKKKKKKKKKKKKK.",
        ".KGGGGGGGGGGGGGGGGGGGGK.",
        ".KGGGGGGGGGGGGGGGGGGGGK.",
        ".KGGGGGGGGGGGGGGGGGGGGK.",
        ".KGYYWGGYYWGGYYWGGYYWGK.",
        ".KGWWWGGWWWGGWWWGGWWWGK.",
        ".KGWWWGGWWWGGWWWGGWWWGK.",
        ".KGWWWGGWWWGGWWWGGWWWGK.",
        ".KGGGGGGGGGGGGGGGGGGGGK.",
        ".KGGGGGGGGGGGGGGGGGGGGK.",
        ".KGGGGGGGGGGGGGGGGGGGGK.",
        ".KKKKKKKKKKKKKKKKKKKKKK.",
    ]

    /// Puffs from small to large; S smoke, T its shaded edge.
    static let puffs = [
        ["SS",
         "ST"],
        [".SS.",
         "SSSS",
         "SSST",
         ".ST."],
        [".SSS.",
         "SSSSS",
         "SSSSS",
         "SSSST",
         ".STT."],
    ]

    static let palette: [Character: Color] = [
        "K": Color(red: 0.18, green: 0.20, blue: 0.22),
        "G": Color(red: 0.55, green: 0.57, blue: 0.61),
        "W": Color(red: 1.00, green: 0.71, blue: 0.18),
        "Y": Color(red: 1.00, green: 0.85, blue: 0.47),
        "S": Color(red: 0.84, green: 0.86, blue: 0.88),
        "T": Color(red: 0.67, green: 0.69, blue: 0.72),
    ]

    struct Dot: Equatable {
        var x: Int
        var y: Int
        var color: Color
        var opacity: Double
    }

    /// Where each puff sits along its path from the chimney mouth (0) to the upper left (1): position, size, fading.
    static func puff(progress: Double) -> (x: Int, y: Int, size: Int, opacity: Double) {
        let p = min(max(progress, 0), 1)
        let size = p < 0.25 ? 0 : (p < 0.6 ? 1 : 2)
        let x = Int((18.5 - 11.5 * p).rounded()) - size
        let y = Int((6.4 - 7.0 * p).rounded()) - size
        let opacity = p < 0.8 ? 1.0 : (p < 0.92 ? 0.6 : 0.3)
        return (x, y, size, opacity)
    }

    /// The still logo has three puffs along the path; while working, four puffs travel it, one after another.
    static func dots(at time: TimeInterval?) -> [Dot] {
        var dots: [Dot] = []
        for (row, line) in factory.enumerated() {
            for (column, symbol) in line.enumerated() {
                if let color = palette[symbol] {
                    dots.append(Dot(x: column, y: row + smokeRows, color: color, opacity: 1))
                }
            }
        }
        let progresses: [Double]
        if let time {
            let cycle = 2.4
            let base = time.truncatingRemainder(dividingBy: cycle) / cycle
            progresses = (0..<4).map { (base + Double($0) / 4).truncatingRemainder(dividingBy: 1) }
        } else {
            progresses = [0.1, 0.4, 0.7]
        }
        for progress in progresses {
            let puff = puff(progress: progress)
            for (row, line) in puffs[puff.size].enumerated() {
                for (column, symbol) in line.enumerated() {
                    let x = puff.x + column, y = puff.y + row
                    guard let color = palette[symbol], (0..<width).contains(x), (0..<smokeRows + 2).contains(y) else { continue }
                    dots.append(Dot(x: x, y: y, color: color, opacity: puff.opacity))
                }
            }
        }
        return dots
    }
}
