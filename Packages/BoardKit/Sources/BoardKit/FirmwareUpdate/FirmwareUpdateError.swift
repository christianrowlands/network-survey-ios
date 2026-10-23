import BoardProtocol
import Foundation

/// Everything that can stop a firmware update, each with text for the user.
public enum FirmwareUpdateError: Error, Equatable, Sendable {
    // Finding and checking the firmware.
    case manifestUnavailable(String)
    case manifestInvalid(String)
    case manifestSignatureInvalid
    case unsupportedManifestFormat(Int)
    case noTrustedKeys
    case staleRelease(version: String, minimum: String)
    case noImageForBoard(String)
    case downloadFailed(String)
    case imageCorrupt(String)
    case signatureInvalid
    case notAnAppImage
    case fileChoice
    case wrongChip(board: String, image: String)

    // Talking to the board.
    case surveyRunning
    case boardBusy
    case notConnected
    case connectionLost
    case bondMissing
    case pairingRejected
    case boardRejected(String)
    case imageTooLarge
    case flashWriteFailed
    case verifyFailed
    case protocolError(String)

    // After the restart.
    case boardDidNotReturn
    case rolledBack(version: String)
    case notConfirmed(version: String)
    case unexpectedVersion(expected: String, found: String)

    case cancelled

    public var userMessage: String {
        switch self {
        case .manifestUnavailable(let detail):
            "Could not check for firmware updates (\(detail)). Check the internet connection and try again."
        case .manifestInvalid:
            "The firmware release information could not be read. Try again later."
        case .manifestSignatureInvalid:
            "The firmware release is not signed by a trusted key, so it was not used."
        case .unsupportedManifestFormat:
            "This firmware release needs a newer version of the app. Update the app first."
        case .noTrustedKeys:
            "This build of the app has no firmware signing key, so it cannot install official updates."
        case .staleRelease(let version, let minimum):
            "The release server offers firmware \(version), but versions below \(minimum) are no longer considered safe. The server may be out of date; try again later."
        case .noImageForBoard(let model):
            "There is no official firmware for \(model). Use Install from file to install your own build."
        case .downloadFailed(let detail):
            "The firmware download failed (\(detail)). Try again."
        case .imageCorrupt:
            "The downloaded firmware is damaged. Try again."
        case .signatureInvalid:
            "The firmware signature does not match a trusted key. The file may have been modified."
        case .notAnAppImage:
            "This file is not an ESP32 app image. Choose the app .bin, not the merged flash image."
        case .fileChoice:
            "Choose one app image (.bin), and optionally its .sig file."
        case .wrongChip(let board, let image):
            "This firmware is built for \(image), but the board has an \(board)."
        case .surveyRunning:
            "Stop the survey before updating the board."
        case .boardBusy:
            "The board is busy. Wait a moment and try again."
        case .notConnected:
            "The board is not connected. Connect it and try again."
        case .connectionLost:
            "The connection to the board was lost and could not be restored. Move the phone closer to the board and try again; the update continues where it stopped."
        case .bondMissing:
            "The board no longer knows this phone. Forget it in Settings > Bluetooth, then pair again."
        case .pairingRejected:
            "The board refused the connection. Hold its BOOT button for 3 seconds to allow pairing, then try again."
        case .boardRejected(let detail):
            "The board refused the update (\(detail))."
        case .imageTooLarge:
            "The firmware does not fit on this board."
        case .flashWriteFailed:
            "The board could not write the firmware to its flash memory. Try again; if it keeps failing, reflash the board over USB."
        case .verifyFailed:
            "The board rejected the firmware after the transfer (checksum or image check failed). The board keeps its current firmware."
        case .protocolError(let detail):
            "The update stopped because of an unexpected answer from the board (\(detail))."
        case .boardDidNotReturn:
            "The board did not reconnect after restarting. Check that it is powered and nearby, then connect it from the Boards screen."
        case .rolledBack(let version):
            "The board went back to firmware \(version): the new firmware did not start correctly."
        case .notConfirmed(let version):
            "The board restarted with firmware \(version) but did not confirm the new image, so it may have gone back to its previous copy. Check the board and install again if needed."
        case .unexpectedVersion(let expected, let found):
            "The board restarted with firmware \(found) instead of \(expected)."
        case .cancelled:
            "The update was cancelled. The board keeps its current firmware."
        }
    }

    /// A transfer may continue after this error (same image, OtaBegin resumes).
    public var isResumable: Bool {
        switch self {
        case .connectionLost, .boardBusy, .notConnected: true
        default: false
        }
    }

    static func from(_ error: BoardTransportError) -> FirmwareUpdateError {
        switch error {
        case .bondMissing: .bondMissing
        case .pairingRejected: .pairingRejected
        case .cancelled: .cancelled
        case .notConnected, .unknownBoard, .bluetoothUnavailable: .notConnected
        case .malformedResponse, .invalidRequest, .unsupported: .protocolError("\(error)")
        default: .connectionLost
        }
    }
}
