/// Picks an operator's color from a 16-color palette with the same hash as the
/// Android app's `PlmnColorMapper`, so an operator looks the same on both. The
/// colors themselves are design tokens in the app.
public enum PlmnPalette {
    public static let size = 16

    public static func index(for plmn: Plmn) -> Int {
        let mcc = Int(plmn.mcc) ?? 0, mnc = Int(plmn.mnc) ?? 0
        return Int((Int32(truncatingIfNeeded: mcc &* 31 &+ mnc) & 0x7FFF_FFFF) % Int32(size))
    }
}
