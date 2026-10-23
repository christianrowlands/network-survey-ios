import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

struct HTTPRequest: Sendable {
    var method: HTTPMethod
    var path: String
    var headers: HTTPHeaders
    var body: Data
}

struct HTTPResponse: Sendable {
    var status: HTTPResponseStatus
    var body: Data

    static func json(_ object: Any, status: HTTPResponseStatus = .ok) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    static func encoded(_ value: some Encodable) -> HTTPResponse {
        HTTPResponse(status: .ok, body: (try? JSONEncoder().encode(value)) ?? Data())
    }
}

/// A small HTTP/1.1 server on a free local port. Each request is answered by
/// `route`, which runs off the event loop (it may start processes).
final class HTTPServer: Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    init(route: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Handler(route: route))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else { throw HarnessError("The HTTP server has no port") }
        self.port = port
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let route: @Sendable (HTTPRequest) async -> HTTPResponse
        private var head: HTTPRequestHead?
        private var body = Data()

        init(route: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
            self.route = route
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                body = Data()
            case .body(var buffer):
                body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            case .end:
                guard let head else { return }
                let request = HTTPRequest(
                    method: head.method, path: String(head.uri.split(separator: "?").first ?? ""),
                    headers: head.headers, body: body
                )
                let keepAlive = head.isKeepAlive
                let version = head.version
                let route = route
                let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
                let promise = context.eventLoop.makePromise(of: HTTPResponse.self)
                promise.completeWithTask { await route(request) }
                promise.futureResult.whenSuccess { response in
                    let (handler, context) = bound.value
                    handler.write(response, version: version, keepAlive: keepAlive, context: context)
                }
            }
        }

        private func write(_ response: HTTPResponse, version: HTTPVersion, keepAlive: Bool, context: ChannelHandlerContext) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(response.body.count))
            if !keepAlive { headers.add(name: "Connection", value: "close") }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: version, status: response.status, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
            if !keepAlive {
                let channel = context.channel
                done.whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }
}
