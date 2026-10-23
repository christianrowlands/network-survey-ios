import SwiftUI

/// The NS Analytics page before this phone is registered: what NS Analytics
/// is, how to get an account, and the three steps to connect. Modeled on the
/// Android app's connect walkthrough. Sections for the settings `Form`.
struct NSAnalyticsIntroSections: View {
    @Binding var scanning: Bool
    var note: String?

    @State private var page: WebPage?

    var body: some View {
        Group {
            Section {
                VStack(spacing: Theme.Spacing.m) {
                    NSAnalyticsIcon(size: 64)
                    Text("NS Analytics")
                        .font(Theme.Fonts.screenTitle)
                        .foregroundStyle(Theme.Colors.ink)
                    Text("The web companion for Network Survey. Every connected phone uploads its surveys to your team's workspace.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.s)
                benefit("map", "See every phone's surveys on one map")
                benefit("chart.bar.xaxis", "An analysis page for each record type, and export when you need the raw records")
                benefit("icloud.and.arrow.up", "Records upload from the field, so nobody copies files off phones")
            } footer: {
                Text("The Starter plan is free.")
            }

            Section {
                step(1, "Create a free account", "Takes a minute. You get your own workspace.") {
                    HStack(spacing: Theme.Spacing.m) {
                        Button {
                            page = WebPage(url: Links.nsAnalyticsSignUp)
                        } label: {
                            Text("Create account").foregroundStyle(Theme.Colors.onAccent)
                        }
                        .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("nsa.signUp")
                        Button("Sign in") { page = WebPage(url: Links.nsAnalyticsSignIn) }
                            .buttonStyle(.borderless)
                    }
                }
                step(2, "Open Devices, then Register Device",
                     "On a computer, go to \(Links.nsAnalyticsHost) and scan the QR code it shows. On this iPhone, tap Copy Link instead, then come back here.") {
                    EmptyView()
                }
                step(3, "Scan the code or paste the link", "That links this phone to the workspace. No password to type.") {
                    HStack(spacing: Theme.Spacing.m) {
                        Button {
                            scanning = true
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "qrcode.viewfinder")
                                Text("Scan QR code")
                            }
                            .foregroundStyle(Theme.Colors.onAccent)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("nsa.scan")
                        PasteLinkButton()
                    }
                }
                RegistrationLinkField()
            } header: {
                Text("How to connect")
            } footer: {
                if let note { Text(note) } else {
                    Text("Only records from surveys that send to NS Analytics are uploaded, and only to this workspace.")
                }
            }

            Section {
                Button {
                    page = WebPage(url: Links.nsAnalyticsLearnMore)
                } label: {
                    Label("Learn more about NS Analytics", systemImage: "info.circle")
                }
            }
        }
        .sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Colors.accentInk)
        }
    }

    private func step<Actions: View>(
        _ number: Int, _ title: String, _ detail: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text("\(number)")
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.Colors.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(title)
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(Theme.Colors.ink)
                Text(detail)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title)")
    }
}
