import SafariServices
import SwiftUI

/// The Network Survey app tile: the folded map on its own light ground, so it
/// works in light and dark mode.
struct BrandTile: View {
    var size: CGFloat = 28

    var body: some View {
        Image("NSIconTile")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The stacked Network Survey lockup (mark over the outlined wordmark), with
/// the white colorway in dark mode. At least 120 points wide.
struct BrandLockup: View {
    var width: CGFloat = 160

    var body: some View {
        Image("NSLockupStacked")
            .resizable()
            .scaledToFit()
            .frame(width: max(width, 120))
            .accessibilityLabel("Network Survey")
    }
}

/// The NS Analytics hexagon icon. Only on NS Analytics screens.
struct NSAnalyticsIcon: View {
    var size: CGFloat = 56

    var body: some View {
        Image("NSAnalyticsIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A web page in an in-app Safari sheet, so the user comes straight back.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A page to show in a `SafariView` sheet: `.sheet(item: $page) { SafariView(url: $0.url) }`.
struct WebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
