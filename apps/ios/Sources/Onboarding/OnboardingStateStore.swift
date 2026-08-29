import Foundation

enum OnboardingConnectionMode: String, CaseIterable {
    case homeNetwork = "home_network"
    case remoteDomain = "remote_domain"
    case developerLocal = "developer_local"

    var title: String {
        switch self {
        case .homeNetwork:
            "Home Network"
        case .remoteDomain:
            "Remote Domain"
        case .developerLocal:
            "Same Machine (Dev)"
        }
    }
}

enum OnboardingStateStore {
    private static let completedDefaultsKey = "onboarding.completed"
    private static let firstRunIntroSeenDefaultsKey = "onboarding.first_run_intro_seen"
    private static let lastModeDefaultsKey = "onboarding.last_mode"
    private static let lastSuccessTimeDefaultsKey = "onboarding.last_success_time"
    private static let mobileSetupBlockedDefaultsKey = "onboarding.mobile_setup_blocked"

    @MainActor
    static func shouldPresentOnLaunch(
        appModel: NodeAppModel,
        defaults: UserDefaults = .standard,
        hasSavedGatewayConnection: Bool? = nil)
        -> Bool
    {
        if defaults.bool(forKey: self.mobileSetupBlockedDefaultsKey) { return true }
        if defaults.bool(forKey: self.completedDefaultsKey), appModel.mobileSetupComplete { return false }
        let hasSavedGatewayConnection =
            hasSavedGatewayConnection ?? (GatewaySettingsStore.loadLastGatewayConnection() != nil)
        if hasSavedGatewayConnection { return false }
        return !appModel.mobileSetupComplete
    }

    static func markCompleted(mode: OnboardingConnectionMode? = nil, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: self.completedDefaultsKey)
        defaults.set(false, forKey: self.mobileSetupBlockedDefaultsKey)
        if let mode {
            defaults.set(mode.rawValue, forKey: self.lastModeDefaultsKey)
        }
        defaults.set(Int(Date().timeIntervalSince1970), forKey: Self.lastSuccessTimeDefaultsKey)
    }

    static func shouldPresentFirstRunIntro(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: self.firstRunIntroSeenDefaultsKey)
    }

    static func markFirstRunIntroSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: self.firstRunIntroSeenDefaultsKey)
    }

    static func markIncomplete(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: self.completedDefaultsKey)
        defaults.set(true, forKey: self.mobileSetupBlockedDefaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: self.completedDefaultsKey)
        defaults.set(false, forKey: self.mobileSetupBlockedDefaultsKey)
        defaults.set(false, forKey: self.firstRunIntroSeenDefaultsKey)
    }

    static func lastMode(defaults: UserDefaults = .standard) -> OnboardingConnectionMode? {
        let raw = defaults.string(forKey: Self.lastModeDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return OnboardingConnectionMode(rawValue: raw)
    }
}
