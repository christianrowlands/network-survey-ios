import SurveyCore
import SwiftUI
import UIKit

extension View {
    /// Applies the Appearance setting to every window scene, so sheets, full
    /// screen covers and alerts follow it too. Attach once, on the tab view.
    func appAppearance() -> some View {
        modifier(AppAppearance())
    }
}

private struct AppAppearance: ViewModifier {
    @Environment(SettingsModel.self) private var settings

    func body(content: Content) -> some View {
        let preference = settings[Settings.appearance]
        content
            .environment(\.palette, preference == .midnight ? .midnight : .standard)
            .onChange(of: preference, initial: true) { _, preference in
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    apply(preference, to: scene)
                }
            }
    }

    private func apply(_ preference: AppearancePreference, to scene: UIWindowScene) {
        switch preference {
        case .system: scene.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        case .light: scene.traitOverrides.userInterfaceStyle = .light
        case .dark, .midnight: scene.traitOverrides.userInterfaceStyle = .dark
        }
        scene.traitOverrides[PaletteTrait.self] = preference == .midnight ? .midnight : .standard
    }
}
