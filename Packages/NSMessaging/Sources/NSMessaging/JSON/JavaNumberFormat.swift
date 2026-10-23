import Foundation

/// Number formatting that matches the Java runtime, because the Network Survey
/// Android app writes its JSON and CSV with Java's `Float.toString`,
/// `Double.toString`, `String.format("%.6f")` and `DecimalFormat`.
public enum JavaNumberFormat {
    /// Java `Float.toString`: the shortest digits that identify the value,
    /// plain between 1e-3 and 1e7 ("-52.0", "13.3"), otherwise scientific
    /// ("1.0E7", "1.0E-5").
    public static func string(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return format(ShortestDecimal(value.description), magnitude: Double(value.magnitude))
    }

    /// Java `Double.toString`, with the same rules as `string(_: Float)`.
    public static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return format(ShortestDecimal(value.description), magnitude: value.magnitude)
    }

    /// Java `String.format("%.6f", value)`: half-up rounding of the shortest
    /// decimal digits, always six decimals.
    public static func fixed(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return string(value) }
        var decimal = ShortestDecimal(value.description)
        decimal.round(toDecimals: decimals, mode: .halfUp)
        return decimal.plain(minFractionDigits: decimals, maxFractionDigits: decimals)
    }

    /// Java `new DecimalFormat("#.##")` with `RoundingMode.CEILING`, as the
    /// Android CSV loggers use for altitude, speed and accuracy: rounds toward
    /// positive infinity, drops trailing zeros ("13.31", "5", "0.5", "-0").
    public static func ceilingTwoDecimals(_ value: Double) -> String {
        guard value.isFinite else { return string(value) }
        var decimal = ShortestDecimal(value.description)
        decimal.round(toDecimals: 2, mode: .ceiling)
        return decimal.plain(minFractionDigits: 0, maxFractionDigits: 2)
    }

    private static func format(_ decimal: ShortestDecimal, magnitude: Double) -> String {
        if decimal.digits.isEmpty { return decimal.negative ? "-0.0" : "0.0" }
        if magnitude >= 1e-3 && magnitude < 1e7 {
            return decimal.plain(minFractionDigits: 1, maxFractionDigits: Int.max)
        }
        let digits = Array(decimal.digits)
        var text = decimal.negative ? "-" : ""
        text.append(digits[0])
        text.append(".")
        text.append(digits.count > 1 ? String(digits[1...]) : "0")
        text.append("E\(decimal.exponent - 1)")
        return text
    }
}

/// A decimal number as significant digits and an exponent:
/// value = 0.digits x 10^exponent. Built from Swift's shortest round-trip
/// description, which gives the same digits as Java's `toString`.
struct ShortestDecimal {
    enum Rounding { case halfUp, ceiling }

    var negative: Bool
    /// Significant digits without leading or trailing zeros. Empty means zero.
    var digits: String
    var exponent: Int

    init(_ description: String) {
        var text = Substring(description)
        negative = text.hasPrefix("-")
        if negative { text = text.dropFirst() }
        var power = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            power = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts.first.map(String.init) ?? ""
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        var all = integer + fraction
        var point = integer.count + power
        while all.hasPrefix("0") {
            all.removeFirst()
            point -= 1
        }
        while all.hasSuffix("0") { all.removeLast() }
        digits = all
        exponent = all.isEmpty ? 0 : point
    }

    /// Rounds to `decimals` digits after the decimal point.
    mutating func round(toDecimals decimals: Int, mode: Rounding) {
        guard !digits.isEmpty else { return }
        let keep = exponent + decimals
        guard keep < digits.count else { return }
        let all = Array(digits)
        var kept = keep > 0 ? Array(all[..<keep]) : []
        let firstDropped: Character = keep >= 0 ? all[keep] : "0"
        let roundUp: Bool
        switch mode {
        case .halfUp: roundUp = firstDropped >= "5"
        // Like Java's DigitList, a value more than one position below the last
        // kept decimal becomes zero without rounding (0.0001 gives "0").
        case .ceiling: roundUp = !negative && keep >= 0
        }
        if roundUp {
            var index = kept.count - 1
            while index >= 0 && kept[index] == "9" {
                kept[index] = "0"
                index -= 1
            }
            if index >= 0 {
                kept[index] = Character(String(kept[index].wholeNumberValue! + 1))
            } else {
                kept.insert("1", at: 0)
            }
        }
        // kept is now the value times 10^decimals, as an integer.
        var text = String(kept)
        while text.hasPrefix("0") { text.removeFirst() }
        let length = text.count
        while text.hasSuffix("0") { text.removeLast() }
        digits = text
        exponent = text.isEmpty ? 0 : length - decimals
    }

    /// Plain notation with a bounded number of fraction digits.
    func plain(minFractionDigits: Int, maxFractionDigits: Int) -> String {
        var integer = ""
        var fraction = ""
        if digits.isEmpty {
            integer = "0"
        } else if exponent <= 0 {
            integer = "0"
            fraction = String(repeating: "0", count: -exponent) + digits
        } else if exponent >= digits.count {
            integer = digits + String(repeating: "0", count: exponent - digits.count)
        } else {
            integer = String(digits.prefix(exponent))
            fraction = String(digits.dropFirst(exponent))
        }
        if fraction.count > maxFractionDigits { fraction = String(fraction.prefix(maxFractionDigits)) }
        if fraction.count < minFractionDigits {
            fraction += String(repeating: "0", count: minFractionDigits - fraction.count)
        }
        let sign = negative ? "-" : ""
        return fraction.isEmpty ? sign + integer : sign + integer + "." + fraction
    }
}
