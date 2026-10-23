import SwiftUI

/// What an NS Scout is, how to get one, how to install its software and how
/// to pair it, page by page. Opened from the Scouts screen, the Survey
/// screen's "Still to do" panel, the welcome and Settings.
struct ScoutGuideView: View {
    enum Page: Int, CaseIterable {
        case meet, get, install, pair, demo
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page
    @State private var web: WebPage?
    @State private var copied = false

    init(start: Page = .meet) {
        _page = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    meet.tag(Page.meet)
                    get.tag(Page.get)
                    install.tag(Page.install)
                    pair.tag(Page.pair)
                    demo.tag(Page.demo)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                ActionBar {
                    Button {
                        if let next = Page(rawValue: page.rawValue + 1) {
                            withAnimation { page = next }
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text(page == Page.allCases.last ? "Done" : "Next")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("scoutGuide.next")
                }
            }
            .screenBackground()
            .navigationTitle("NS Scout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $web) { SafariView(url: $0.url).ignoresSafeArea() }
        }
    }

    // MARK: - Pages

    private var meet: some View {
        GuidePage(symbol: "sensor.fill", title: "Meet NS Scout") {
            GuideText("A small sensor that listens for the Wi-Fi and Bluetooth around you and sends what it hears to this iPhone over Bluetooth.")
            GuideText("iPhones don't let apps scan Wi-Fi, so the Scout does the listening. Network Survey adds the location and shows it all on the map.")
            GuidePoint("ear", "It only listens. It never transmits Wi-Fi frames.")
            GuidePoint("bolt.fill", "Runs on USB power. A phone power bank works in the field.")
            GuidePoint("square.stack.3d.up", "Use up to four Scouts at once to cover more channels.")
        }
    }

    private var get: some View {
        GuidePage(symbol: "shippingbox.fill", title: "Get a Scout") {
            GuideText("An NS Scout is an inexpensive ESP32 development board running the free Network Survey Scout software.")
            GuidePoint("star.fill", "Recommended: Espressif ESP32-C5-DevKitC-1. The ESP32-C5 is the only chip that hears 5 GHz Wi-Fi as well as 2.4 GHz.")
            GuidePoint("checklist", "Also works: Seeed Studio XIAO ESP32-C5, and ESP32-C6, ESP32-S3 or ESP32-C3 boards (2.4 GHz only).")
            GuidePoint("cable.connector", "You also need a USB cable that carries data, not just power.")
            Button {
                web = WebPage(url: Links.scout)
            } label: {
                Label("Where to buy", systemImage: "cart")
                    .foregroundStyle(Theme.Colors.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("scoutGuide.buy")
        }
    }

    private var install: some View {
        GuidePage(symbol: "laptopcomputer.and.arrow.down", title: "Install the Scout software") {
            GuideText("Do this once, on a computer with Chrome or Edge.")
            GuideStep(1, "Plug the board into the computer with the USB cable.")
            GuideStep(2, "Go to \(Links.scoutInstaller.host() ?? "the installer page") and click Install.")
            GuideStep(3, "Pick the board's port when the browser asks, then wait for it to finish.")
            GuideText("Or send yourself the link:")
            HStack(spacing: Theme.Spacing.m) {
                ShareLink(item: Links.scoutInstaller) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Theme.Colors.onAccent)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    UIPasteboard.general.url = Links.scoutInstaller
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            GuideText("Later updates install from this app over Bluetooth, so you only need the computer the first time.")
        }
    }

    private var pair: some View {
        GuidePage(symbol: "link", title: "Pair it with this iPhone") {
            GuideStep(1, "Power the Scout. A fast cyan blink means it is ready to pair.")
            GuideStep(2, "Hold it next to your iPhone and open Scouts on the Survey screen.")
            GuideStep(3, "Tap Connect, then tap Pair when iOS asks.")
            GuideText("The light on the Scout:")
            GuidePoint("circle.fill", "Fast cyan blink: ready to pair", tint: .cyan)
            GuidePoint("circle.fill", "Short blue blink: waiting for its phone", tint: .blue)
            GuidePoint("circle.fill", "Solid blue: connected", tint: .blue)
            GuidePoint("circle.fill", "Slow green blink: surveying", tint: .green)
            GuideText("Paired with someone else's phone? Hold the small button labelled BOOT (B on XIAO boards) for 3 seconds. The light blinks cyan and the Scout is ready to pair with you.")
        }
    }

    private var demo: some View {
        GuidePage(symbol: "play.circle.fill", title: "No Scout yet?") {
            GuideText("Try the demo Scout. It makes up Wi-Fi and Bluetooth data so you can see how a survey works. Demo data is never sent to NS Analytics.")
            Toggle("Demo Scout", isOn: Binding(
                get: { model.demoBoardEnabled },
                set: { enabled in Task { await model.setDemoBoardEnabled(enabled) } }
            ))
            .tint(Theme.Colors.accent)
            .disabled(model.survey.isLocked)
            .accessibilityIdentifier("scoutGuide.demo")
            GuideText("Turn it off in Scouts when your real one arrives.")
        }
    }
}

// MARK: - Building blocks, shared with the welcome

/// A scrolling guide page: a large symbol, a title and content.
struct GuidePage<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.Colors.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.xxl)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                content
            }
            .padding(.horizontal, Theme.Spacing.screenGutter)
            .padding(.bottom, 56)  // Clear of the page dots.
            .frame(maxWidth: Theme.Spacing.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

struct GuideText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GuidePoint: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.Colors.accentInk

    init(_ symbol: String, _ text: String, tint: Color = Theme.Colors.accentInk) {
        self.symbol = symbol
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GuideStep: View {
    let number: Int
    let text: String
    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text("\(number)")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.Colors.accent))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}
