import SwiftUI

enum KstColor {
    static let paper0 = Color(hex: 0xfaf7f1)
    static let paper1 = Color(hex: 0xf5f1e8)
    static let paper2 = Color(hex: 0xede7d8)
    static let paper3 = Color(hex: 0xe3dccb)

    static let ink0 = Color(hex: 0x1c1814)
    static let ink1 = Color(hex: 0x3a342c)
    static let ink2 = Color(hex: 0x6b6358)
    static let ink3 = Color(hex: 0x9a9085)
    static let ink4 = Color(hex: 0xc8bfb1)

    static let cerulean     = Color(oklch: 0.62, 0.13, 235)
    static let ceruleanSoft = Color(oklch: 0.92, 0.04, 235)
    static let ceruleanInk  = Color(oklch: 0.42, 0.10, 235)

    static let iris     = Color(oklch: 0.62, 0.13, 285)
    static let irisSoft = Color(oklch: 0.92, 0.04, 285)
    static let irisInk  = Color(oklch: 0.42, 0.10, 285)

    static let sage     = Color(oklch: 0.62, 0.08, 155)
    static let sageSoft = Color(oklch: 0.92, 0.03, 155)
    static let sageInk  = Color(oklch: 0.42, 0.06, 155)

    static let amber     = Color(oklch: 0.72, 0.12, 70)
    static let amberSoft = Color(oklch: 0.94, 0.04, 70)
    static let amberInk  = Color(oklch: 0.45, 0.10, 70)

    static let graphiteBg   = Color(hex: 0x3a342c)
    static let graphiteSoft = Color(hex: 0xede7d8)
    static let graphiteInk  = Color(hex: 0x1c1814)

    static let dangerInk = Color(oklch: 0.55, 0.15, 35)
}

extension AccentTone {
    var base: Color {
        switch self {
        case .cerulean: KstColor.cerulean
        case .iris:     KstColor.iris
        case .sage:     KstColor.sage
        case .amber:    KstColor.amber
        case .graphite: KstColor.graphiteBg
        }
    }
    var soft: Color {
        switch self {
        case .cerulean: KstColor.ceruleanSoft
        case .iris:     KstColor.irisSoft
        case .sage:     KstColor.sageSoft
        case .amber:    KstColor.amberSoft
        case .graphite: KstColor.graphiteSoft
        }
    }
    var ink: Color {
        switch self {
        case .cerulean: KstColor.ceruleanInk
        case .iris:     KstColor.irisInk
        case .sage:     KstColor.sageInk
        case .amber:    KstColor.amberInk
        case .graphite: KstColor.graphiteInk
        }
    }
}

enum KstRadius {
    static let r1: CGFloat = 4
    static let r2: CGFloat = 6
    static let r3: CGFloat = 10
    static let r4: CGFloat = 14
    static let r5: CGFloat = 20
}

enum KstShadow {
    static func one() -> some View {
        Color.clear
            .shadow(color: Color.black.opacity(0.06), radius: 0.5, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
    }
}

extension View {
    func kstShadow1() -> some View {
        self
            .shadow(color: Color.black.opacity(0.06), radius: 0.5, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
    }
    func kstShadow2() -> some View {
        self
            .shadow(color: Color.black.opacity(0.06), radius: 0.5, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.06), radius: 1.5, x: 0, y: 1)
            .shadow(color: Color.black.opacity(0.05), radius: 7, x: 0, y: 4)
    }
    func kstShadowPop() -> some View {
        self
            .shadow(color: Color.black.opacity(0.10), radius: 0.5, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
    }
}
