import Foundation

/// SplitMix64: a small, fast generator whose output depends only on its seed.
/// Swift's `SystemRandomNumberGenerator` cannot be seeded, so the simulator uses this.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A generator for an independent sub-stream, so adding draws in one part of
    /// the simulation does not shift the values of another.
    public func derived(_ salt: UInt64) -> SeededGenerator {
        var copy = SeededGenerator(seed: state ^ (salt &* 0xD1B5_4A32_D192_ED03))
        _ = copy.next()
        return copy
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < p
    }

    /// Roughly normal noise (sum of uniforms), mean 0.
    public mutating func noise(sigma: Double) -> Double {
        var sum = 0.0
        for _ in 0..<4 { sum += Double.random(in: -1...1, using: &self) }
        return sum * sigma * 0.866
    }

    public mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &self) }
    }
}
