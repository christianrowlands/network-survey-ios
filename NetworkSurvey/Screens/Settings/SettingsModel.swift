import Foundation
import Observation
import SurveyCore
import SwiftUI

/// Makes `SettingsStore` observable for SwiftUI: every change (from any
/// screen or from code) bumps `revision`, and bindings read through it.
@Observable
final class SettingsModel {
    @ObservationIgnored let store: SettingsStore
    private(set) var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: SettingsStore) {
        self.store = store
        let changes = store.changes()
        task = Task { [weak self] in
            for await _ in changes {
                self?.revision += 1
            }
        }
    }

    deinit {
        task?.cancel()
    }

    subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            _ = revision
            return store[key]
        }
        set {
            store[key] = newValue
            revision += 1
        }
    }

    func binding<Value>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    func secret(_ key: SecretKey) -> String {
        _ = revision
        return store.secret(key) ?? ""
    }

    /// Writes a secret to the Keychain; an empty value removes it.
    func setSecret(_ value: String, for key: SecretKey) {
        try? store.setSecret(value, for: key)
        revision += 1
    }
}
