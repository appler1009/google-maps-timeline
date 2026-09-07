import SwiftUI

enum Palette {
    static let ink = Color(red: 0.07, green: 0.11, blue: 0.16)
    static let inkLift = Color(red: 0.11, green: 0.16, blue: 0.22)
    static let rule = Color(red: 0.22, green: 0.30, blue: 0.36)
    static let parchment = Color(red: 0.93, green: 0.89, blue: 0.82)
    static let muted = Color(red: 0.62, green: 0.66, blue: 0.68)
    static let copper = Color(red: 0.72, green: 0.42, blue: 0.22)
    static let water = Color(red: 0.16, green: 0.45, blue: 0.42)
    static let path = Color(red: 0.78, green: 0.36, blue: 0.22)

    static func distance(meters: Double) -> Color {
        let km = max(0, meters / 1000)
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.22, 0.48, 0.46)),
            (15, (0.32, 0.52, 0.40)),
            (35, (0.58, 0.50, 0.28)),
            (60, (0.72, 0.42, 0.22)),
            (90, (0.80, 0.32, 0.18)),
            (160, (0.86, 0.22, 0.16)),
        ]
        if km <= stops[0].0 {
            let c = stops[0].1
            return Color(red: c.0, green: c.1, blue: c.2)
        }
        for index in 1..<stops.count {
            let (hi, hc) = stops[index]
            let (lo, lc) = stops[index - 1]
            if km <= hi {
                let u = (km - lo) / (hi - lo)
                return Color(
                    red: lc.0 + (hc.0 - lc.0) * u,
                    green: lc.1 + (hc.1 - lc.1) * u,
                    blue: lc.2 + (hc.2 - lc.2) * u
                )
            }
        }
        let c = stops[stops.count - 1].1
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}
