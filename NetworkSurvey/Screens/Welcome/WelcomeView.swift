import SwiftUI

/// Shown once, at first launch: what Network Survey does and what it needs
/// (an NS Scout), with a way forward whether or not the user has one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var showingGuide = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                intro.tag(0)
                scout.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            ActionBar { actions }
        }
        .screenBackground()
        .sheet(isPresented: $showingGuide) {
            ScoutGuideView(start: .get)
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                BrandLockup(width: 180)
                    .padding(.top, 56)
                Text("Map the Wi-Fi and Bluetooth around you.")
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GuidePoint("map", "See every access point and Bluetooth device you pass, on a map.")
                    GuidePoint("doc.text", "Save surveys as CSV files you can open anywhere.")
                    GuidePoint("person.3", "Share them with your team in NS Analytics.")
                    GuidePoint("lock", "Your data stays on this iPhone unless you choose to send it.")
                }
            }
            .padding(.horizontal, Theme.Spacing.screenGutter)
            .padding(.bottom, 56)
            .frame(maxWidth: Theme.Spacing.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var scout: some View {
        GuidePage(symbol: "sensor.fill", title: "You'll need an NS Scout") {
            GuideText("iPhones don't let apps scan Wi-Fi, so Network Survey uses an NS Scout: a small sensor that listens for Wi-Fi and Bluetooth and sends what it hears to this iPhone.")
            GuideText("It's an inexpensive ESP32 board you can buy online and set up in a few minutes. No Scout yet? Try the demo Scout and see how a survey works.")
        }
    }

    @ViewBuilder private var actions: some View {
        if page == 0 {
            Button("Next") { withAnimation { page = 1 } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("welcome.next")
        } else {
            Button {
                model.finishWelcome()
                model.openBoards()
            } label: {
                Text("I have a Scout")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("welcome.haveScout")
            HStack(spacing: Theme.Spacing.m) {
                Button("How to get one") { showingGuide = true }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Try the demo") {
                    Task {
                        await model.setDemoBoardEnabled(true)
                        model.finishWelcome()
                        model.openBoards()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("welcome.demo")
            }
        }
    }
}
