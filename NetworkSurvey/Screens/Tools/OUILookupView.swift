import SwiftUI

/// Type a MAC address, or its first 6 hex digits, and see who it is
/// registered to. Uses the registries built into the app, so it works offline.
struct OUILookupView: View {
    @State private var text: String
    @FocusState private var focused: Bool

    /// `address` fills in the field (a detail screen's MAC address).
    init(address: String = "") {
        _text = State(initialValue: address.uppercased())
    }

    var body: some View {
        let digits = OUIRegistry.hexDigits(text)
        List {
            Group {
                Section {
                    TextField("MAC address", text: $text, prompt: Text("AC:DE:48:00:11:22"))
                        .font(Theme.Fonts.mono)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                        .focused($focused)
                        .accessibilityIdentifier("oui.input")
                } footer: {
                    Text("Enter a full address or at least the first 6 hex digits. Manufacturers come from the IEEE MA-L, MA-M and MA-S registries (\(DataFormat.count(OUIRegistry.table.count)) prefixes) built into the app, so lookups never leave this iPhone.")
                }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        if let digits, digits.count >= 6 {
                            OUIResultView(match: OUIRegistry.lookup(digits: digits, in: OUIRegistry.table), digits: digits)
                        } else if digits == nil {
                            message("Not a MAC address", "Use hex digits (0 to 9 and A to F), with or without colons or dashes, 12 digits at most.")
                        } else {
                            message("Keep typing", "The first 6 hex digits are needed to find the manufacturer.")
                        }
                    }
                    .accessibilityIdentifier("oui.result")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("OUI lookup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = text.isEmpty }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.Colors.ink)
            Text(detail).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.ink2)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

private struct OUIResultView: View {
    let match: OUIMatch
    let digits: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(match.vendor == nil ? Theme.Colors.ink2 : Theme.Colors.ink)
                .textSelection(.enabled)
            if let detail {
                Text(detail).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
        if let registry = match.registry, let prefix = match.prefix {
            DetailRow(label: "Prefix", value: prefix, mono: true)
            DetailRow(label: "Registry", value: "\(registry.rawValue) (\(registry.bits)-bit prefix)")
        }
        if digits.count == 12 {
            DetailRow(label: "Address", value: OUIRegistry.format(digits), mono: true)
        }
    }

    private var title: String {
        switch match.kind {
        case .vendor(let name): name
        case .privateVendor: "Private"
        case .sharedBlock: "Shared block"
        case .locallyAdministered: "Randomized address"
        case .multicast: "Multicast address"
        case .notFound: "No match"
        }
    }

    private var detail: String? {
        switch match.kind {
        case .vendor: nil
        case .privateVendor:
            "The prefix is registered, but the organization asked the IEEE not to publish its name."
        case .sharedBlock:
            "These 6 digits are split into smaller blocks owned by different organizations. Enter more of the address to find which one."
        case .locallyAdministered:
            "The locally administered bit is set, so this address was assigned by software, most often a private address that changes over time. It is not in any registry."
        case .multicast:
            "The group bit is set, so this is a multicast or broadcast address, not a single device."
        case .notFound:
            "This prefix is not in the registries built into this version of the app."
        }
    }
}

/// A detail screen's Manufacturer row, opening OUI lookup for the address
/// to show the registry entry.
struct ManufacturerLink: View {
    let address: String
    let vendor: String
    var label = "Manufacturer"

    var body: some View {
        NavigationLink {
            OUILookupView(address: address)
        } label: {
            DetailRow(label: label, value: vendor)
        }
        .accessibilityHint("Looks up the manufacturer")
        .accessibilityIdentifier("detail.manufacturer")
    }
}
