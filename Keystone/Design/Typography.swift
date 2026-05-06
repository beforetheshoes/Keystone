import SwiftUI

enum KstFontFamily {
    static let display = ["Avenir Next", "Avenir", "Nunito Sans", "-apple-system", "Helvetica Neue"]
    static let text    = ["Avenir Next", "Avenir", "Nunito Sans", "-apple-system", "Helvetica Neue"]
    static let mono    = ["SF Mono", "JetBrains Mono", "Menlo"]
}

extension Font {
    static func kstText(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", size: size, relativeTo: .body).weight(weight)
    }
    static func kstDisplay(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Avenir Next", size: size, relativeTo: .title).weight(weight)
    }
    static func kstMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
