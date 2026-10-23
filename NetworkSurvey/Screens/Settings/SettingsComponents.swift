import SurveyCore
import SwiftUI

/// A labeled text field row for a string setting.
struct SettingTextField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var keyboard = UIKeyboardType.default
    var identifier = ""

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
        }
    }
}

/// An integer setting edited as text. Invalid or empty input is not saved;
/// leaving the field puts the stored value back.
struct SettingNumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...Int.max
    var identifier = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .monospacedDigit()
                .focused($focused)
                .accessibilityIdentifier(identifier)
                .onAppear { text = String(value) }
                .onChange(of: value) { _, newValue in
                    if !focused { text = String(newValue) }
                }
                .onChange(of: text) { _, newText in
                    if let number = Int(newText.filter(\.isNumber)), range.contains(number), number != value {
                        value = number
                    }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { text = String(value) }
                }
        }
    }
}

/// A secret kept in the Keychain. Saved when editing ends or the page closes.
struct SecretField: View {
    let title: String
    let key: SecretKey
    var identifier = ""

    @Environment(SettingsModel.self) private var settings
    @State private var text = ""
    @State private var stored = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            SecureField(title, text: $text, prompt: Text("None"))
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .focused($focused)
                .accessibilityIdentifier(identifier)
                .onAppear {
                    stored = settings.secret(key)
                    text = stored
                }
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { save() }
                }
                .onDisappear(perform: save)
        }
    }

    private func save() {
        guard text != stored else { return }
        settings.setSecret(text, for: key)
        stored = text
    }
}

/// Footer reminding that settings are read when a survey starts.
struct AppliesNextSurveyFooter: View {
    var extra: String?

    var body: some View {
        Text([extra, "Changes apply when the next survey starts."].compactMap { $0 }.joined(separator: " "))
    }
}

/// A destination row on the Settings list with a one-line state.
struct SettingsLinkLabel: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        LabeledContent {
            Text(detail)
                .lineLimit(1)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
