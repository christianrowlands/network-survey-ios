import Foundation

/// A workspace registration link or QR code:
/// `https://networksurvey.app/app/register?token=...&workspace_id=...&api_url=https://...&workspace_name=...`.
/// Validated like the Network Survey Android app does.
public struct NSAnalyticsLink: Sendable, Equatable {
    public enum Problem: Error, Equatable, Sendable {
        case notARegistrationLink, missingToken, missingWorkspace, missingServer
        case serverNotHTTPS, badServer, localServer, serverTooLong, nameTooLong
    }

    public var token: String
    public var workspaceID: String
    public var apiURL: URL
    public var workspaceName: String?

    public init(token: String, workspaceID: String, apiURL: URL, workspaceName: String? = nil) {
        self.token = token
        self.workspaceID = workspaceID
        self.apiURL = apiURL
        self.workspaceName = workspaceName
    }

    public init(url: URL) throws(Problem) {
        guard url.host?.lowercased() == "networksurvey.app", url.path.hasPrefix("/app/register"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw .notARegistrationLink
        }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
        let name = value("workspace_name")
        if let name, name.count > 100 { throw .nameTooLong }
        guard let token = value("token") else { throw .missingToken }
        guard let workspaceID = value("workspace_id") else { throw .missingWorkspace }
        guard let server = value("api_url") else { throw .missingServer }
        guard server.hasPrefix("https://") else { throw .serverNotHTTPS }
        guard let apiURL = URL(string: server), let host = apiURL.host?.lowercased() else { throw .badServer }
        let privatePatterns = [
            #"^127\.\d+\.\d+\.\d+$"#, #"^10\.\d+\.\d+\.\d+$"#, #"^172\.(1[6-9]|2\d|3[01])\.\d+\.\d+$"#,
            #"^192\.168\.\d+\.\d+$"#, #"^169\.254\.\d+\.\d+$"#,
        ]
        if host == "localhost" || privatePatterns.contains(where: { host.range(of: $0, options: .regularExpression) != nil }) {
            throw .localServer
        }
        guard server.count <= 255 else { throw .serverTooLong }
        self.init(token: token, workspaceID: workspaceID, apiURL: apiURL, workspaceName: name)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What a successful registration leaves behind. Keep it in the Keychain.
public struct NSAnalyticsRegistration: Sendable, Equatable, Codable {
    public var deviceToken: String
    public var deviceID: String
    public var workspaceID: String
    public var workspaceName: String?
    public var apiURL: URL

    public init(deviceToken: String, deviceID: String, workspaceID: String, workspaceName: String?, apiURL: URL) {
        self.deviceToken = deviceToken
        self.deviceID = deviceID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.apiURL = apiURL
    }
}

/// Where the registration lives (the app uses the Keychain).
public protocol NSAnalyticsCredentialStore: Sendable {
    func load() -> NSAnalyticsRegistration?
    func save(_ registration: NSAnalyticsRegistration)
    func clear()
}

/// A credential store in memory, for tests and previews.
public final class InMemoryCredentialStore: NSAnalyticsCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NSAnalyticsRegistration?

    public init(_ value: NSAnalyticsRegistration? = nil) { self.value = value }
    public func load() -> NSAnalyticsRegistration? { lock.withLock { value } }
    public func save(_ registration: NSAnalyticsRegistration) { lock.withLock { value = registration } }
    public func clear() { lock.withLock { value = nil } }
}

/// Sends one HTTP request. `URLSessionTransport` covers ordinary sessions; the
/// app uses `BackgroundUploadTransport` so uploads finish after a survey stops.
public protocol NSAnalyticsTransport: Sendable {
    /// `taskID` names the request (the upload batch ID) so a background upload
    /// that completes after an app relaunch can be matched to its batch.
    func send(_ request: URLRequest, body: Data, taskID: String) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: NSAnalyticsTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, body: Data, taskID: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = body.isEmpty
            ? try await session.data(for: request)
            : try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why registering this phone with a workspace failed, as the Android app sorts it.
public enum NSAnalyticsRegistrationError: Error, Equatable, Sendable {
    case network
    case codeRejected
    case deviceLimit
    case license
    case server
    case other(String?)

    static func classify(status: Int, body: Data) -> Self {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = json?["error"] as? String
        let code = json?["error_code"] as? String
        if status >= 500 { return .server }
        if code == "LICENSE_EXPIRED" { return .license }
        if code == "LICENSE_DEVICE_LIMIT" { return .deviceLimit }
        if status == 400, let message, ["Invalid or expired token", "Token already used", "Token expired"].contains(message) {
            return .codeRejected
        }
        if status == 400, message?.hasPrefix("Device limit reached") == true { return .deviceLimit }
        if status == 401 { return .codeRejected }
        return .other(message)
    }
}

/// The NS Analytics device API (`api/v1/device/...` under the link's `api_url`).
public struct NSAnalyticsClient: Sendable {
    public struct DeviceInfo: Sendable, Equatable {
        /// The per-install ID, the same as the records' deviceSerialNumber.
        public var deviceID: String
        public var deviceName: String
        public var deviceModel: String
        /// For example "iOS 18.0".
        public var osVersion: String
        public var appVersion: String

        public init(deviceID: String, deviceName: String, deviceModel: String, osVersion: String, appVersion: String) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.deviceModel = deviceModel
            self.osVersion = osVersion
            self.appVersion = appVersion
        }
    }

    public let transport: any NSAnalyticsTransport
    static let timeout: TimeInterval = 30

    public init(transport: any NSAnalyticsTransport) {
        self.transport = transport
    }

    static func request(_ base: URL, _ path: String, method: String = "POST", token: String? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Registers this phone with the workspace from a registration link.
    public func register(_ link: NSAnalyticsLink, device: DeviceInfo) async throws(NSAnalyticsRegistrationError) -> NSAnalyticsRegistration {
        let body: [String: String] = [
            "token": link.token, "device_id": device.deviceID, "device_name": device.deviceName,
            "device_model": device.deviceModel, "os_version": device.osVersion, "app_version": device.appVersion,
        ]
        let data: Data
        let response: HTTPURLResponse
        do {
            let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            (data, response) = try await transport.send(
                Self.request(link.apiURL, "api/v1/device/register"), body: encoded, taskID: "register"
            )
        } catch {
            throw .network
        }
        guard (200..<300).contains(response.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["device_token"] as? String else {
            throw NSAnalyticsRegistrationError.classify(status: response.statusCode, body: data)
        }
        func text(_ key: String) -> String? { json[key].map { "\($0)" } }
        return NSAnalyticsRegistration(
            deviceToken: token, deviceID: text("device_id") ?? device.deviceID,
            workspaceID: text("workspace_id") ?? link.workspaceID,
            workspaceName: (json["workspace_name"] as? String) ?? link.workspaceName, apiURL: link.apiURL
        )
    }

    /// GET api/v1/device/status: whether the registration is still active.
    /// Nil if the server could not be asked.
    public func isActive(_ registration: NSAnalyticsRegistration) async -> Bool? {
        let request = Self.request(registration.apiURL, "api/v1/device/status", method: "GET", token: registration.deviceToken)
        guard let (data, response) = try? await transport.send(request, body: Data(), taskID: "status"),
              response.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["is_active"] as? Bool
    }

    /// POST api/v1/device/unregister. True when the server confirmed it or
    /// already considers the phone unregistered (401 or 403).
    public func unregister(_ registration: NSAnalyticsRegistration) async -> Bool {
        let request = Self.request(registration.apiURL, "api/v1/device/unregister", token: registration.deviceToken)
        guard let (data, response) = try? await transport.send(request, body: Data(), taskID: "unregister") else { return false }
        if response.statusCode == 401 || response.statusCode == 403 { return true }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (200..<300).contains(response.statusCode) && json?["success"] as? Bool == true
    }
}
