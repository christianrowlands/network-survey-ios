import BoardProtocol
import NSMessaging
import SurveyCore
import SwiftUI

struct BLEDetailView: View {
    let sessionID: String
    let address: String

    var body: some View {
        LiveDetail(query: { [sessionID, address] store in
            store.observe { try StoreQueries.bleDeviceDetail($0, sessionID: sessionID, address: address) }
        }) { detail in
            BLEDetailContent(detail: detail)
        }
        .navigationTitle("Bluetooth device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IgnoreMenu(choices: [IgnoreChoice(kind: .mac, value: address, title: "Ignore this device (address)")])
            }
        }
    }
}

private struct BLEDetailContent: View {
    let detail: BLEDeviceDetail

    var body: some View {
        let device = detail.device
        let advertising = AdvertisingData(device.advData)
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(device.name?.isEmpty == false ? device.name! : "Unnamed device")
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.ink)
                            .accessibilityAddTraits(.isHeader)
                        TagRow {
                            if let company = device.companyId {
                                TagPill(text: BLECompanies.name(for: company) ?? BLECompanies.hexID(company), color: Theme.Colors.bluetooth)
                            }
                            if DataFormat.isPrivateBLEAddress(device.address, addressType: device.addressType) { RandomizedBadge() }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Signal") {
                    RSSIChart(points: detail.rssiHistory)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                Section("Identity") {
                    DetailRow(label: "Address", value: device.address, mono: true)
                    DetailRow(label: "Address type", value: addressTypeText(device))
                    if let company = device.companyId {
                        DetailRow(label: "Company", value: companyText(company))
                    }
                    DetailRow(label: "Advertising", value: DataFormat.bleAdvType(device.advType))
                    if let txPower = device.txPower { DetailRow(label: "TX power", value: DataFormat.dBm(txPower)) }
                    ForEach(advertising.serviceUUIDs, id: \.self) { uuid in
                        ServiceRow(uuid: uuid)
                    }
                }
                Section {
                    if device.advData.isEmpty {
                        Text("No advertising data.").foregroundStyle(Theme.Colors.ink2)
                    } else {
                        ForEach(Array(ADStructure.split(device.advData).enumerated()), id: \.offset) { _, structure in
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(structure.typeName)
                                    .font(Theme.Fonts.label)
                                    .foregroundStyle(Theme.Colors.ink2)
                                Text(DataFormat.hex(structure.value))
                                    .font(Theme.Fonts.mono)
                                    .foregroundStyle(Theme.Colors.ink)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: {
                    Text("Advertising data")
                } footer: {
                    Text("\(device.advData.count) bytes from the last advertisement, split into AD structures.")
                }
                ObservationSection(entity: device)
            }
            .panelRows()
        }
        .themedList()
        .listStyle(.insetGrouped)
    }

    private func addressTypeText(_ device: BLEDeviceRow) -> String {
        let type = DataFormat.bleAddressType(device.addressType)
        guard NSBBleAddressType(rawValue: device.addressType) == .random else { return type }
        return DataFormat.isPrivateBLEAddress(device.address, addressType: device.addressType)
            ? "Random (private, changes over time)" : "Random (static)"
    }

    private func companyText(_ id: Int) -> String {
        if let name = BLECompanies.name(for: id) { return "\(name) (\(BLECompanies.hexID(id)))" }
        return BLECompanies.hexID(id)
    }
}

/// An advertised service UUID, short form and name when known.
struct ServiceRow: View {
    let uuid: String

    var body: some View {
        LabeledContent("Service") {
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(BLEServiceUUIDs.display(uuid))
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                if let name = BLEServiceUUIDs.name(forUUID: uuid) {
                    Text(name)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }
}

/// One length-type-value structure of BLE advertising data.
nonisolated struct ADStructure: Equatable {
    var type: UInt8
    var value: Data

    var typeName: String {
        let hex = String(format: "0x%02X", type)
        let name: String? = switch type {
        case 0x00: "Unparsed"
        case 0x01: "Flags"
        case 0x02, 0x03: "16-bit service UUIDs"
        case 0x04, 0x05: "32-bit service UUIDs"
        case 0x06, 0x07: "128-bit service UUIDs"
        case 0x08: "Shortened name"
        case 0x09: "Complete name"
        case 0x0A: "TX power level"
        case 0x16: "Service data (16-bit UUID)"
        case 0x19: "Appearance"
        case 0xFF: "Manufacturer data"
        default: nil
        }
        return name.map { "\($0) (\(hex))" } ?? "Type \(hex)"
    }

    /// Splits AD structures. Stops at a zero length (padding); a truncated
    /// structure is kept whole as type 0 ("Unparsed").
    static func split(_ data: Data) -> [ADStructure] {
        let bytes = [UInt8](data)
        var result: [ADStructure] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { break }
            let end = index + 1 + length
            guard end <= bytes.count, length >= 1 else {
                result.append(ADStructure(type: 0, value: Data(bytes[index...])))
                break
            }
            result.append(ADStructure(type: bytes[index + 1], value: Data(bytes[(index + 2)..<end])))
            index = end
        }
        return result
    }
}
