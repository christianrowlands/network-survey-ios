import Foundation
import SwiftProtobuf
import Testing
@testable import BoardProtocol

private func roundTrip<M: Message & Equatable>(_ message: M) throws -> M {
    let bytes: Data = try message.serializedData()
    let decoded = try M(serializedBytes: bytes)
    #expect(decoded == message)
    return decoded
}

private let bssid = Data([0x02, 0x00, 0x5E, 0x10, 0x00, 0x01])
private let clientMac = Data([0x0A, 0x11, 0x22, 0x33, 0x44, 0x55])

@Suite struct MessageRoundTripTests {
    @Test func protocolVersionConstants() {
        #expect(NSBProtocolVersion.major.rawValue == 1)
        #expect(NSBProtocolVersion.minor.rawValue == 0)
    }

    @Test func boardInfo() throws {
        let info = NSBBoardInfo.with {
            $0.protocolMajor = 1
            $0.firmwareVersion = "0.1.0"
            $0.boardModel = .xiaoEsp32C5
            $0.chip = .esp32C5
            $0.bands = [.ghz24, .ghz5]
            $0.gpsPresent = true
            $0.shortID = "ABCD"
            $0.preferredMtu = 517
            $0.btAddress = Data([0x02, 0x00, 0x5E, 0x00, 0xAB, 0xCD])
        }
        let decoded = try roundTrip(info)
        #expect(decoded.bands == [.ghz24, .ghz5])
    }

    @Test(arguments: [
        NSBControlRequest.OneOf_Command.hello(.with { $0.protocolMajor = 1; $0.appVersion = "1.0.0" }),
        .setTime(.with { $0.unixTimeMs = 1_767_225_600_123 }),
        .configure(.with {
            $0.wifiAp = true
            $0.role = .fixedChannel
            $0.channels = [149]
            $0.rawTypeMask = 0b101
        }),
        .start(NSBStart()),
        .stop(NSBStop()),
        .enterPairingMode(NSBEnterPairingMode()),
        .forgetBonds(NSBForgetBonds()),
        .otaBegin(.with { $0.imageSize = 1_200_000; $0.sha256 = Data(repeating: 0xAB, count: 32) }),
        .otaEnd(NSBOtaEnd()),
        .otaAbort(NSBOtaAbort()),
        .ping(.with { $0.nonce = 0xDEAD_BEEF }),
    ])
    func controlRequest(_ command: NSBControlRequest.OneOf_Command) throws {
        let request = NSBControlRequest.with {
            $0.requestID = 42
            $0.command = command
        }
        let decoded = try roundTrip(request)
        #expect(decoded.command == command)
    }

    @Test(arguments: [
        NSBControlResponse.OneOf_Payload.hello(.with {
            $0.protocolMajor = 1
            $0.compatible = true
            $0.firmwareVersion = "0.1.0"
        }),
        .configure(.with { $0.channels = [1, 6, 11]; $0.role = .band24; $0.rawSnaplen = 128 }),
        .otaBegin(.with { $0.maxChunkSize = 240; $0.windowBytes = 4096; $0.startOffset = 8192 }),
        .ping(.with { $0.nonce = 7; $0.boardTimeMs = 99; $0.timeSynced = true }),
    ])
    func controlResponse(_ payload: NSBControlResponse.OneOf_Payload) throws {
        let response = NSBControlResponse.with {
            $0.requestID = 42
            $0.result = .ok
            $0.payload = payload
        }
        _ = try roundTrip(response)
    }

    @Test func controlResponseError() throws {
        let response = NSBControlResponse.with {
            $0.requestID = 3
            $0.result = .incompatible
            $0.message = "major mismatch"
        }
        let decoded = try roundTrip(response)
        #expect(decoded.payload == nil)
    }

    @Test func boardStatus() throws {
        let status = NSBBoardStatus.with {
            $0.state = .surveying
            $0.role = .bleSniffer
            $0.droppedRecords = 12
            $0.gpsState = .fix
            $0.batteryMv = 3700
            $0.pairingMode = true
        }
        let decoded = try roundTrip(status)
        #expect(decoded.hasBatteryMv)
    }

    @Test(arguments: [
        NSBRecord.OneOf_Kind.ap(.with {
            $0.bssid = bssid
            $0.ssid = Data("ExampleNet".utf8)
            $0.rssiMax = -40
            $0.security = .owe
            $0.akmSuites = [0x000F_AC12]
            $0.channelWidth = .mhz80
            $0.beaconIntervalTu = 100
        }),
        .client(.with {
            $0.clientMac = clientMac
            $0.associatedBssid = bssid
            $0.sourceFlags = UInt32(NSBClientSource.data.rawValue | NSBClientSource.auth.rawValue)
            $0.locallyAdministered = true
        }),
        .probe(.with { $0.clientMac = clientMac; $0.ssid = Data(); $0.count = 4 }),
        .ble(.with {
            $0.address = Data([0xC2, 0x00, 0x5E, 0x00, 0x00, 0x01])
            $0.addressType = .random
            $0.advData = Data([0x02, 0x01, 0x06])
            $0.companyID = 0xFFFF
            $0.txPower = -8
        }),
        .gps(.with { $0.latitude = 39.7392; $0.longitude = -104.9903; $0.altitudeM = 1609.5 }),
    ])
    func recordBatch(_ kind: NSBRecord.OneOf_Kind) throws {
        let batch = NSBRecordBatch.with {
            $0.timeSynced = true
            $0.records = [.with { $0.kind = kind }, .with { $0.kind = kind }]
        }
        let decoded = try roundTrip(batch)
        #expect(decoded.records.count == 2)
        #expect(decoded.records[1].kind == kind)
    }

    @Test func rawFrame() throws {
        let frame = NSBRawFrame.with {
            $0.boardTimeUs = 1_767_225_600_123_456
            $0.phy = .he
            $0.mcs = 7
            $0.origLen = 1500
            $0.data = Data(repeating: 0x88, count: 128)
        }
        let decoded = try roundTrip(frame)
        #expect(decoded.hasMcs && !decoded.hasNoiseFloorDbm)
    }

    @Test func otaAck() throws {
        _ = try roundTrip(NSBOtaAck.with { $0.nextOffset = 4096; $0.status = .outOfOrder })
    }

    @Test func unknownFieldsFromNewerMinorAreIgnored() throws {
        // A newer board may add field 99 (varint 5) to BoardStatus.
        var bytes: Data = try NSBBoardStatus.with { $0.currentChannel = 6 }.serializedData()
        bytes.append(contentsOf: [0x98, 0x06, 0x05])
        let decoded = try NSBBoardStatus(serializedBytes: bytes)
        #expect(decoded.currentChannel == 6)
    }
}

@Suite struct MessageHelperTests {
    @Test func helloUsesPackageVersion() {
        let hello = NSBHello.current(appVersion: "1.2.3")
        #expect(hello.protocolMajor == 1 && hello.protocolMinor == 0)
        #expect(hello.appVersion == "1.2.3")
    }

    @Test func helloTruncatesAppVersionOnCharacterBoundary() throws {
        let long = String(repeating: "a", count: 30) + "\u{00E9}\u{00E9}"  // 30 + 2 + 2 bytes
        let hello = NSBHello.current(appVersion: long)
        #expect(hello.appVersion.utf8.count == 30)
        #expect(BoardLimits.truncateUTF8("\u{1F4E1}abc", maxBytes: 3) == "")
        #expect(BoardLimits.truncateUTF8("abc", maxBytes: 31) == "abc")
    }

    @Test func invalidUTF8NameStillDecodes() throws {
        let ble = NSBBleObservation.with { $0.localName = Data([0x4E, 0x53, 0xFF, 0xC3]) }
        let decoded = try NSBBleObservation(serializedBytes: ble.serializedData() as Data)
        #expect(decoded.localName == Data([0x4E, 0x53, 0xFF, 0xC3]))
        #expect(decoded.localNameText.hasPrefix("NS"))
    }
}
