#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// `NearbyScanner` on CoreBluetooth: an unfiltered scan, foreground only. Its
/// own `CBCentralManager`, separate from the NS Scout connection and without
/// state restoration, created on the first `start()` so the Bluetooth prompt
/// only appears when the user chooses to look.
public final class CoreBluetoothNearbyScanner: NSObject, NearbyScanner, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.networksurvey.NearbyKit.ble")
    private let stream: AsyncStream<NearbyScannerEvent>
    private let continuation: AsyncStream<NearbyScannerEvent>.Continuation
    // Queue-confined state.
    private var manager: CBCentralManager?
    private var wantsScan = false

    override public init() {
        (stream, continuation) = AsyncStream.makeStream(of: NearbyScannerEvent.self, bufferingPolicy: .bufferingNewest(1_000))
        super.init()
    }

    deinit {
        continuation.finish()
    }

    public var authorization: NearbyAuthorization {
        switch CBManager.authorization {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        default: .allowed
        }
    }

    public var radio: NearbyRadioState {
        queue.sync { manager.map { Self.map($0.state) } ?? .unknown }
    }

    public func events() -> AsyncStream<NearbyScannerEvent> { stream }

    public func start() {
        queue.async { [self] in
            wantsScan = true
            if manager == nil {
                manager = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            scanIfPossible()
        }
    }

    public func stop() {
        queue.async { [self] in
            wantsScan = false
            if manager?.state == .poweredOn { manager?.stopScan() }
        }
    }

    private func scanIfPossible() {
        guard wantsScan, let manager, manager.state == .poweredOn, !manager.isScanning else { return }
        // Duplicates on, so the signal stays live.
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private static func map(_ state: CBManagerState) -> NearbyRadioState {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        default: .unknown
        }
    }
}

extension CoreBluetoothNearbyScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        continuation.yield(.state(Self.map(central.state)))
        scanIfPossible()
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        continuation.yield(.advertisement(NearbyAdvertisement(
            peripheralID: peripheral.identifier,
            time: Date(),
            rssi: RSSI.intValue,
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? [],
            serviceDataUUIDs: serviceData.keys.map(\.uuidString).sorted(),
            txPower: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )))
    }
}
#endif
