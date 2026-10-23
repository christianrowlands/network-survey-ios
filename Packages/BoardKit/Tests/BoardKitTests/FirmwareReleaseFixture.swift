import Foundation

/// Output of the firmware repository's scripts/sign-release.sh, signed with the
/// DEV / TEST ONLY key, over two synthetic 1500-byte app images (see `image`).
/// Checks that the app verifies exactly what the release tooling produces.
enum FirmwareReleaseFixture {
    static let manifest = Data((#"""
{
  "format": 1,
  "name": "Network Survey Board firmware",
  "version": "0.1.0",
  "min_version": "0.1.0",
  "protocol_major": 1,
  "protocol_minor": 0,
  "released": "2026-10-24T00:00:00Z",
  "images": [
    {
      "board": "esp32c5-devkitc1",
      "board_model": "ESP32_C5_DEVKITC_1",
      "chip": "ESP32_C5",
      "file": "network-survey-board-esp32c5-devkitc1-0.1.0.bin",
      "url": "network-survey-board-esp32c5-devkitc1-0.1.0.bin",
      "size": 1500,
      "sha256": "74cc0b741c921c651c145809f40366c04f41c257711890b4d3ca3d073803b733",
      "signature": "Rl8Zu+P1AjudDhbICtXQqytfQoX4lX8pDPdlckouDUHbLVFp0+UuETyget5b231c2r80S6HHi7BmT7dWUqwMAQ=="
    },
    {
      "board": "esp32c3-devkitm1",
      "board_model": "ESP32_C3_GENERIC",
      "chip": "ESP32_C3",
      "file": "network-survey-board-esp32c3-devkitm1-0.1.0.bin",
      "url": "network-survey-board-esp32c3-devkitm1-0.1.0.bin",
      "size": 1500,
      "sha256": "7c54bfc54a13947cf12795c9321d60872e8ff209f7cf6cdb68c3ce57046e560c",
      "signature": "eF2KpKB5y+K3NrT1yW/TOAUtDBsFmdiBNKdQD8FONA8QZz4CPaUiPOLx0HLG3qKs/LXwVuu+STu98/SzRDSaBw=="
    }
  ]
}
"""# + "\n").utf8)

    static let manifestSignature = Data("FfM58rDHwJ9dLBS5Ajt8zjz/fEVn9bke8ApKfM/6SQxm7rm3WLZX5BZ8gG5nhIDdq71zGp9nQ0lKIKzONVR6DA==\n".utf8)

    /// The synthetic image the fixture was signed over: an app image header
    /// for `chipID` and `version`, then a fixed byte pattern.
    static func image(chipID: UInt16, version: String = "0.1.0", size: Int = 1500) -> Data {
        var bytes = [UInt8](repeating: 0, count: 112)
        bytes[0] = 0xE9
        bytes[1] = 3
        bytes[12] = UInt8(chipID & 0xFF)
        bytes[13] = UInt8(chipID >> 8)
        bytes.replaceSubrange(32..<36, with: [0x32, 0x54, 0xCD, 0xAB])
        bytes.replaceSubrange(48..<(48 + version.utf8.count), with: Array(version.utf8))
        let project = Array("network_survey_board".utf8)
        bytes.replaceSubrange(80..<(80 + project.count), with: project)
        for index in 112..<size {
            bytes.append(UInt8((index * 31 + 7) & 0xFF))
        }
        return Data(bytes)
    }
}
