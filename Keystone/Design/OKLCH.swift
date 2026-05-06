import Foundation
import SwiftUI

struct OKLCH: Equatable, Sendable {
    var l: Double
    var c: Double
    var h: Double

    func toSRGB() -> (r: Double, g: Double, b: Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        let lr = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let lg = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let lb = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        return (encodeSRGB(lr), encodeSRGB(lg), encodeSRGB(lb))
    }

    private func encodeSRGB(_ v: Double) -> Double {
        let clipped = max(0, min(1, v))
        if clipped <= 0.0031308 { return 12.92 * clipped }
        return 1.055 * pow(clipped, 1.0 / 2.4) - 0.055
    }
}

extension Color {
    init(oklch l: Double, _ c: Double, _ h: Double) {
        let rgb = OKLCH(l: l, c: c, h: h).toSRGB()
        self = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
