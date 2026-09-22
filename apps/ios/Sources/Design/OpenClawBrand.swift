import SwiftUI

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance.preference"

    static var launchArgumentPreference: AppAppearancePreference? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--openclaw-appearance") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return AppAppearancePreference(rawValue: arguments[valueIndex].lowercased())
    }

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

enum OpenClawBrand {
    static let lightCanvasTop = Color(red: 246 / 255.0, green: 247 / 255.0, blue: 249 / 255.0)
    static let lightCanvasMiddle = Color(red: 250 / 255.0, green: 251 / 255.0, blue: 252 / 255.0)
    static let lightCanvasBottom = Color.white
    static let darkCanvasTop = Color(red: 5 / 255.0, green: 13 / 255.0, blue: 22 / 255.0)
    static let darkCanvasMiddle = Color(red: 7 / 255.0, green: 17 / 255.0, blue: 30 / 255.0)
    static let darkCanvasBottom = Color(red: 11 / 255.0, green: 26 / 255.0, blue: 44 / 255.0)

    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 60 / 255.0, green: 222 / 255.0, blue: 250 / 255.0, alpha: 1)
            : UIColor(red: 0 / 255.0, green: 101 / 255.0, blue: 121 / 255.0, alpha: 1)
    })
    static let accentHot = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 101 / 255.0, green: 232 / 255.0, blue: 255 / 255.0, alpha: 1)
            : UIColor(red: 0 / 255.0, green: 112 / 255.0, blue: 140 / 255.0, alpha: 1)
    })
    // Cyan fills need dark ink in dark appearance; the deeper light-mode tint
    // uses white. Keeping the pair together preserves filled-control contrast.
    static let accentInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 3 / 255.0, green: 33 / 255.0, blue: 50 / 255.0, alpha: 1)
            : UIColor.white
    })
    static let danger = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 252 / 255.0, green: 165 / 255.0, blue: 165 / 255.0, alpha: 1)
            : UIColor(red: 185 / 255.0, green: 28 / 255.0, blue: 28 / 255.0, alpha: 1)
    })
    static let ok = Color(red: 34 / 255.0, green: 197 / 255.0, blue: 94 / 255.0)
    static let warn = Color(red: 245 / 255.0, green: 158 / 255.0, blue: 11 / 255.0)
    static let graphite = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 7 / 255.0, green: 17 / 255.0, blue: 30 / 255.0, alpha: 1)
            : UIColor(red: 246 / 255.0, green: 247 / 255.0, blue: 249 / 255.0, alpha: 1)
    })
    static let graphiteElevated = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 16 / 255.0, green: 43 / 255.0, blue: 64 / 255.0, alpha: 1)
            : UIColor.white
    })
    static let graphiteSoft = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 148 / 255.0, green: 163 / 255.0, blue: 184 / 255.0, alpha: 1)
            : UIColor(red: 102 / 255.0, green: 112 / 255.0, blue: 133 / 255.0, alpha: 1)
    })

    static var sheetBackground: LinearGradient {
        LinearGradient(
            colors: [
                graphite,
                graphiteElevated.opacity(0.96),
                Color(uiColor: .systemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    static var toolbarChrome: LinearGradient {
        LinearGradient(
            colors: [
                graphiteElevated.opacity(0.92),
                graphite.opacity(0.78),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    static func glassFill(brighten: Bool) -> Color {
        Color.black.opacity(brighten ? 0.10 : 0.22)
    }

    static func glassStroke(brighten: Bool, increasedContrast: Bool, active: Bool = false) -> Color {
        if active {
            return self.accent.opacity(increasedContrast ? 0.70 : 0.46)
        }
        return Color.white.opacity(increasedContrast ? 0.50 : (brighten ? 0.24 : 0.16))
    }

    static func formSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(self.accent)
            .textCase(.uppercase)
    }

    static func canvasColors(for colorScheme: ColorScheme) -> [Color] {
        colorScheme == .dark
            ? [self.darkCanvasTop, self.darkCanvasMiddle, self.darkCanvasBottom]
            : [self.lightCanvasTop, self.lightCanvasMiddle, self.lightCanvasBottom]
    }
}

extension View {
    func openClawSheetChrome() -> some View {
        self
            .tint(OpenClawBrand.accent)
            .background {
                OpenClawBrand.sheetBackground
                    .ignoresSafeArea()
            }
    }
}
