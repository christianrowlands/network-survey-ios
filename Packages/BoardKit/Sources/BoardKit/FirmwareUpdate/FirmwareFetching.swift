import Foundation

/// Size limits for everything the update flow downloads or reads.
public enum FirmwareLimits {
    /// Largest image the app accepts. The biggest app partition is under 4 MB.
    public static let maxImageBytes = 8 * 1024 * 1024
    /// Largest manifest or signature file.
    public static let maxManifestBytes = 256 * 1024
}

/// Downloads for the firmware update: the manifest, its signature, images.
public protocol FirmwareFetching: Sendable {
    /// Fails with `FirmwareFetchError.tooLarge` past `maxBytes`, before holding more.
    func data(from url: URL, maxBytes: Int) async throws -> Data
}

public enum FirmwareFetchError: Error, Equatable, LocalizedError {
    case tooLarge(limit: Int)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let limit): "larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit"
        case .http(let status): "HTTP \(status)"
        }
    }
}

public struct URLSessionFirmwareFetcher: FirmwareFetching {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Streams the body so an oversized or endless response is cut off at `maxBytes`.
    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FirmwareFetchError.http(http.statusCode)
        }
        if response.expectedContentLength > Int64(maxBytes) { throw FirmwareFetchError.tooLarge(limit: maxBytes) }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maxBytes)))))
        for try await byte in bytes {
            guard data.count < maxBytes else { throw FirmwareFetchError.tooLarge(limit: maxBytes) }
            data.append(byte)
        }
        return data
    }
}
