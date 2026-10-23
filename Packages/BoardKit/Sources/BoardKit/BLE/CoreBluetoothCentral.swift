#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// `BLECentral` on CoreBluetooth. Every CoreBluetooth object lives on one
/// serial queue; only value types leave it, through the event stream.
public final class CoreBluetoothCentral: NSObject, BLECentral, @unchecked Sendable {
    private static let service = CBUUID(string: BoardGATT.serviceUUID)

    private let queue = DispatchQueue(label: "app.networksurvey.BoardKit.ble")
    private let stream: AsyncStream<BLECentralEvent>
    private let continuation: AsyncStream<BLECentralEvent>.Continuation
    // Queue-confined state.
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [UUID: [BoardCharacteristic: CBCharacteristic]] = [:]
    private var wantsScan = false

    /// On iOS a restore identifier opts in to state restoration; the app must
    /// have the `bluetooth-central` background mode.
    public init(restoreIdentifier: String? = nil) {
        (stream, continuation) = AsyncStream.makeStream(of: BLECentralEvent.self)
        super.init()
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        #if os(iOS)
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        #endif
        queue.sync {
            manager = CBCentralManager(delegate: self, queue: queue, options: options)
        }
    }

    deinit {
        continuation.finish()
    }

    public func events() -> AsyncStream<BLECentralEvent> { stream }

    public var powerState: BLEPowerState {
        queue.sync { Self.map(manager?.state ?? .unknown) }
    }

    public func startScan() {
        queue.async { [self] in
            wantsScan = true
            scanIfPossible()
        }
    }

    public func stopScan() {
        queue.async { [self] in
            wantsScan = false
            if manager?.state == .poweredOn { manager?.stopScan() }
        }
    }

    public func knownPeripherals(_ ids: [UUID]) -> [UUID] {
        queue.sync {
            guard let manager, manager.state == .poweredOn else { return [] }
            let found = manager.retrievePeripherals(withIdentifiers: ids)
            found.forEach(adopt)
            return found.map(\.identifier)
        }
    }

    public func connect(_ id: UUID) {
        queue.async { [self] in
            guard let manager, manager.state == .poweredOn else {
                yield(.connectFailed(id, BLEError(kind: .notConnected, message: "Bluetooth is not on")))
                return
            }
            guard let peripheral = peripheral(id) else {
                yield(.connectFailed(id, BLEError(kind: .notFound, message: "unknown peripheral")))
                return
            }
            manager.connect(peripheral, options: nil)
        }
    }

    public func cancelConnection(_ id: UUID) {
        queue.async { [self] in
            guard let peripheral = peripherals[id], manager?.state == .poweredOn else { return }
            manager?.cancelPeripheralConnection(peripheral)
        }
    }

    public func discoverGATT(_ id: UUID) {
        queue.async { [self] in
            guard let peripheral = peripherals[id], peripheral.state == .connected else {
                yield(.gattDiscovered(id, BLEError(kind: .notConnected, message: "not connected")))
                return
            }
            characteristics[id] = nil
            peripheral.discoverServices([Self.service])
        }
    }

    public func read(_ characteristic: BoardCharacteristic, on id: UUID) {
        withCharacteristic(characteristic, on: id, failure: { .valueUpdated(id, characteristic, Data(), $0) }) {
            $0.readValue(for: $1)
        }
    }

    public func setNotify(_ enabled: Bool, for characteristic: BoardCharacteristic, on id: UUID) {
        withCharacteristic(characteristic, on: id, failure: { .notifyStateChanged(id, characteristic, enabled: false, $0) }) {
            $0.setNotifyValue(enabled, for: $1)
        }
    }

    public func write(_ value: Data, to characteristic: BoardCharacteristic, on id: UUID, withResponse: Bool) {
        withCharacteristic(characteristic, on: id, failure: { .wroteValue(id, characteristic, $0) }) {
            $0.writeValue(value, for: $1, type: withResponse ? .withResponse : .withoutResponse)
        }
    }

    public func canSendWriteWithoutResponse(_ id: UUID) -> Bool {
        queue.sync { peripherals[id]?.canSendWriteWithoutResponse ?? false }
    }

    public func maximumWriteLength(_ id: UUID, withResponse: Bool) -> Int {
        queue.sync { peripherals[id]?.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse) ?? 20 }
    }

    // MARK: - Queue helpers

    private func yield(_ event: BLECentralEvent) {
        continuation.yield(event)
    }

    private func scanIfPossible() {
        guard wantsScan, let manager, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func adopt(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripherals[peripheral.identifier] = peripheral
    }

    private func peripheral(_ id: UUID) -> CBPeripheral? {
        if let peripheral = peripherals[id] { return peripheral }
        guard let peripheral = manager?.retrievePeripherals(withIdentifiers: [id]).first else { return nil }
        adopt(peripheral)
        return peripheral
    }

    private func withCharacteristic(
        _ characteristic: BoardCharacteristic, on id: UUID, failure: @escaping @Sendable (BLEError) -> BLECentralEvent,
        _ body: @escaping @Sendable (CBPeripheral, CBCharacteristic) -> Void
    ) {
        queue.async { [self] in
            guard let peripheral = peripherals[id], peripheral.state == .connected else {
                yield(failure(BLEError(kind: .notConnected, message: "not connected")))
                return
            }
            guard let found = characteristics[id]?[characteristic] else {
                yield(failure(BLEError(kind: .notFound, message: "\(characteristic.rawValue) characteristic not found")))
                return
            }
            body(peripheral, found)
        }
    }

    private static func map(_ state: CBManagerState) -> BLEPowerState {
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

extension CoreBluetoothCentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        yield(.powerState(Self.map(central.state)))
        switch central.state {
        case .resetting, .poweredOff, .unauthorized, .unsupported:
            // CoreBluetooth invalidates every peripheral object; retrieve them again later.
            peripherals.removeAll()
            characteristics.removeAll()
        default:
            break
        }
        scanIfPossible()
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restored.forEach(adopt)
        yield(.restored(restored.map { peripheral in
            let state: BLERestoredPeripheral.State = switch peripheral.state {
            case .connected: .connected
            case .connecting: .connecting
            default: .disconnected
            }
            return BLERestoredPeripheral(id: peripheral.identifier, state: state)
        }))
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        if peripherals[peripheral.identifier] == nil { adopt(peripheral) }
        let advertisement = BLEAdvertisementData(
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? [],
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
        yield(.discovered(peripheral.identifier, advertisement, rssi: RSSI.intValue, name: peripheral.name))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        yield(.connected(peripheral.identifier))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        yield(.connectFailed(peripheral.identifier, error.map(BLEError.init)))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        characteristics[peripheral.identifier] = nil
        yield(.disconnected(peripheral.identifier, error.map(BLEError.init)))
    }
}

extension CoreBluetoothCentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            yield(.gattDiscovered(peripheral.identifier, BLEError(error)))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            yield(.gattDiscovered(peripheral.identifier, BLEError(kind: .notFound, message: "NS Board Service not found")))
            return
        }
        peripheral.discoverCharacteristics(BoardCharacteristic.allCases.map { CBUUID(string: $0.uuidString) }, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            yield(.gattDiscovered(peripheral.identifier, BLEError(error)))
            return
        }
        var found: [BoardCharacteristic: CBCharacteristic] = [:]
        for characteristic in service.characteristics ?? [] {
            if let known = BoardCharacteristic(uuidString: characteristic.uuid.uuidString) { found[known] = characteristic }
        }
        characteristics[peripheral.identifier] = found
        let complete = found[.info] != nil && found[.control] != nil
        yield(.gattDiscovered(peripheral.identifier, complete ? nil : BLEError(kind: .notFound, message: "board characteristics missing")))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let known = BoardCharacteristic(uuidString: characteristic.uuid.uuidString) else { return }
        yield(.valueUpdated(peripheral.identifier, known, characteristic.value ?? Data(), error.map(BLEError.init)))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let known = BoardCharacteristic(uuidString: characteristic.uuid.uuidString) else { return }
        yield(.wroteValue(peripheral.identifier, known, error.map(BLEError.init)))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?
    ) {
        guard let known = BoardCharacteristic(uuidString: characteristic.uuid.uuidString) else { return }
        yield(.notifyStateChanged(peripheral.identifier, known, enabled: characteristic.isNotifying, error.map(BLEError.init)))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        yield(.readyToWriteWithoutResponse(peripheral.identifier))
    }

    /// Service Changed (for example after a firmware update): drop the link so
    /// the reconnect discovers the new GATT table.
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        characteristics[peripheral.identifier] = nil
        manager?.cancelPeripheralConnection(peripheral)
    }
}
#endif
