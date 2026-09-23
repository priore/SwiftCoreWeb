// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOConcurrencyHelpers
import NIOTransportServices
import Network
import Security
import CryptoKit
import os

private let serverLogger = Logger(subsystem: "SwiftCoreWeb", category: "server")

/// The single NIOTransportServices-backed engine that binds one or more
/// listeners (HTTP and, if configured, HTTPS) sharing one `RequestDispatcher`
/// and `WebSocketRegistry`, per the concurrency/lifecycle/network watchdog design.
///
/// `NIOTSListenerBootstrap` (Network.framework) is used for every listener;
/// TLS, when enabled, is the same bootstrap with `NWProtocolTLS.Options`
/// applied — there is no second transport stack.
final class ServerEngine: @unchecked Sendable {
    private let app: WebApplication
    private let dispatcher: RequestDispatcher
    private let rateLimiter: RateLimiter?
    private let connectionGate: ConnectionGate
    private var watchdog: NetworkWatchdog?
    private let listenerChannels = NIOLockedValueBox<[Channel]>([])
    private var bonjourListener: NWListener?
    #if canImport(UIKit)
    // ponytail: KeepAwakeController is @MainActor (touches UIApplication);
    // ServerEngine's init is not, so construction is deferred to first use
    // on the main actor (applyKeepAwakeIfNeeded) instead of a stored default.
    private var keepAwake: KeepAwakeController?
    #endif
    private var previousIdleTimerApplied = false
    private let group: NIOTSEventLoopGroup

    private init(app: WebApplication) {
        self.app = app
        self.dispatcher = app.buildDispatcher()
        self.rateLimiter = app.rateLimitOptions.map(RateLimiter.init)
        self.connectionGate = ConnectionGate(maxConcurrent: app.serverOptions.maxConcurrentConnections)
        self.group = NIOTSEventLoopGroup()
    }

    /// Builds, binds, and runs the engine for `app`, suspending until
    /// `stop(timeout:)` is called. Stores itself on `app.engineBox` so
    /// `stopAsync()` can reach it.
    static func start(for app: WebApplication) async throws {
        let engine = ServerEngine(app: app)
        app.engineBox.engine = engine
        try await engine.run()
    }

    private func run() async throws {
        await applyKeepAwakeIfNeeded()

        try await bindListeners()

        if let bonjourName = app.bonjourName {
            startBonjour(name: bonjourName)
        }

        if app.serverOptions.host == "0.0.0.0" || app.serverOptions.host != "127.0.0.1" {
            let watchdog = NetworkWatchdog { [weak self] in
                await self?.rebindOnNetworkChange()
            }
            self.watchdog = watchdog
            watchdog.start()
        }

        if let rateLimiter {
            Task.detached { [weak self] in
                while self != nil {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard self != nil else { return }
                    await rateLimiter.pruneIdle()
                }
            }
        }

        app.urls = reachableURLs()
        let listeningURLs = app.urls.joined(separator: ", ")
        serverLogger.info("SwiftCoreWeb listening on \(listeningURLs, privacy: .public)")

        // Suspend until every listener channel closes (i.e. until `stop()`
        // closes them), rather than blocking the calling thread.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for channel in listenerChannelsSnapshot() {
                group.addTask { try await channel.closeFuture.get() }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Binding

    private func bindListeners() async throws {
        var bound: [Channel] = []

        let httpChannel = try await makeBootstrap(tls: false)
            .bind(host: app.serverOptions.host, port: app.serverOptions.port)
            .get()
        bound.append(httpChannel)

        if let tlsOptions = app.tlsOptions {
            let tlsChannel = try await makeBootstrap(tls: true, tlsOptions: tlsOptions)
                .bind(host: app.serverOptions.host, port: app.serverOptions.port + 1)
                .get()
            bound.append(tlsChannel)
        }

        listenerChannels.withLockedValue { $0 = bound }
    }

    private func makeBootstrap(tls: Bool, tlsOptions: TlsOptions? = nil) -> NIOTSListenerBootstrap {
        var bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ServerEngineError.stopped)
                }
                return self.configureChildChannel(channel)
            }

        if tls, let tlsOptions {
            guard let identity = try? loadTLSIdentity(tlsOptions) else {
                serverLogger.error("Failed to load TLS identity for .useHttps(...) — HTTPS listener will not start")
                return bootstrap
            }
            bootstrap = bootstrap.tlsOptions(makeTLSOptions(identity: identity))
        }

        return bootstrap
    }

    private func configureChildChannel(_ channel: Channel) -> EventLoopFuture<Void> {
        let remoteIP = channel.remoteAddress?.ipAddress ?? "unknown"
        let promise = channel.eventLoop.makePromise(of: Void.self)

        // Hop to the `ConnectionGate` actor to reserve a slot, then continue
        // pipeline setup back on the channel's event loop. No blocking:
        // `configureChildChannel` returns the pending future immediately.
        Task { [weak self] in
            guard let self else { promise.fail(ServerEngineError.stopped); return }
            guard await self.connectionGate.tryAcquire() else {
                channel.close(promise: nil)
                promise.fail(ServerEngineError.atCapacity)
                return
            }
            channel.eventLoop.execute {
                self.setUpHTTPPipeline(channel, remoteIP: remoteIP).cascade(to: promise)
            }
        }

        return promise.futureResult
    }

    /// Adds the named HTTP1 handlers (WebSocket upgrade removes them by
    /// these names) and starts serving the connection. Runs on the channel's
    /// own event loop, after `ConnectionGate` has reserved a slot.
    private func setUpHTTPPipeline(_ channel: Channel, remoteIP: String) -> EventLoopFuture<Void> {
        channel.pipeline.addHandler(HTTPResponseEncoder(), name: Self.httpEncoderName).flatMap {
            channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()), name: Self.httpDecoderName)
        }.flatMapThrowing { [weak self] in
            guard let self else { throw ServerEngineError.stopped }
            let asyncChannel = try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                wrappingChannelSynchronously: channel
            )
            Task {
                defer { Task { await self.connectionGate.release() } }
                await self.serve(asyncChannel, remoteIP: remoteIP, rawChannel: channel)
            }
        }
    }

    // MARK: - Per-connection serving

    private func serve(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        remoteIP: String,
        rawChannel: Channel
    ) async {
        if let rateLimiter, await !rateLimiter.allow(clientIP: remoteIP) {
            let headers = HTTPHeaders([("Retry-After", "1"), ("Content-Length", "0")])
            try? await channel.outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .tooManyRequests, headers: headers)))
            try? await channel.outbound.write(.end(nil))
            try? await rawChannel.close()
            return
        }

        do {
            try await channel.executeThenClose { inbound, outbound in
                var requestHead: HTTPRequestHead?
                var bodyBuffer = ByteBuffer()
                let maxBodySize = app.serverOptions.maxRequestBodySize

                for try await part in inbound {
                    switch part {
                    case .head(let head):
                        requestHead = head
                        bodyBuffer.clear()

                    case .body(var chunk):
                        bodyBuffer.writeBuffer(&chunk)
                        if bodyBuffer.readableBytes > maxBodySize {
                            try await writeSimpleResponse(outbound, status: .payloadTooLarge)
                            return
                        }

                    case .end:
                        guard let head = requestHead else { continue }

                        if isWebSocketUpgrade(head) {
                            try await handleWebSocketUpgrade(head: head, rawChannel: rawChannel)
                            return
                        }

                        let request = makeHttpRequest(head: head, body: bodyBuffer, remoteAddress: remoteIP)
                        let response = await dispatcher.dispatch(request)
                        try await write(response, method: head.method, to: outbound)
                        requestHead = nil
                        bodyBuffer.clear()
                    }
                }
            }
        } catch {
            serverLogger.debug("Connection from \(remoteIP, privacy: .private) ended: \(String(describing: error), privacy: .public)")
        }
    }

    private func writeSimpleResponse(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        status: HTTPResponseStatus
    ) async throws {
        let headers = HTTPHeaders([("Content-Length", "0")])
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.end(nil))
    }

    private func makeHttpRequest(head: HTTPRequestHead, body: ByteBuffer, remoteAddress: String) -> HttpRequest {
        let uri = head.uri
        let (path, rawQuery) = splitPathAndQuery(uri)
        let (query, queryAll) = parseQueryString(rawQuery)

        var headers = HttpHeaders()
        for (name, value) in head.headers {
            headers.add(name, value)
        }

        let method = HttpMethod(rawValue: head.method.rawValue) ?? .get
        var bodyBuffer = body
        let bodyData = bodyBuffer.readData(length: bodyBuffer.readableBytes) ?? Data()

        return HttpRequest(
            method: method,
            path: path,
            query: query,
            queryAll: queryAll,
            headers: headers,
            remoteAddress: remoteAddress,
            body: bodyData
        )
    }

    private func write(
        _ response: HttpResponse,
        method: HTTPMethod,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        var headers = HTTPHeaders()
        for (name, value) in response.headers.all {
            headers.add(name: name, value: value)
        }

        let dropBody = method == .HEAD

        switch response.body {
        case .empty:
            headers.replaceOrAdd(name: "Content-Length", value: "0")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status.rawValue), headers: headers)))
            try await outbound.write(.end(nil))

        case .text(let string):
            let bytes = Array(string.utf8)
            headers.replaceOrAdd(name: "Content-Length", value: "\(bytes.count)")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status.rawValue), headers: headers)))
            if !dropBody {
                var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                try await outbound.write(.body(.byteBuffer(buffer)))
            }
            try await outbound.write(.end(nil))

        case .json(let data):
            headers.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status.rawValue), headers: headers)))
            if !dropBody {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await outbound.write(.body(.byteBuffer(buffer)))
            }
            try await outbound.write(.end(nil))

        case .data(let data):
            headers.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status.rawValue), headers: headers)))
            if !dropBody {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await outbound.write(.body(.byteBuffer(buffer)))
            }
            try await outbound.write(.end(nil))

        case .file(let path, let range):
            try await writeFile(path, range: range, headers: headers, status: response.status, dropBody: dropBody, outbound: outbound)

        case .stream(let writer):
            headers.remove(name: "Content-Length")
            headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.status.rawValue), headers: headers)))
            if !dropBody {
                let sink = ChunkedByteSink(outbound: outbound)
                try await writer(sink)
            }
            try await outbound.write(.end(nil))
        }
    }

    private func writeFile(
        _ path: String,
        range: ClosedRange<Int>?,
        headers: HTTPHeaders,
        status: HttpStatusCode,
        dropBody: Bool,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        var headers = headers
        guard let fileHandle = FileHandle(forReadingAtPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int else {
            try await writeSimpleResponse(outbound, status: .notFound)
            return
        }
        defer { try? fileHandle.close() }

        // `range` is pre-validated (clamped to the file's bounds) by the
        // static-file middleware, which also sets Content-Range/206 there;
        // this is purely the streamed read for whichever span was requested.
        let span = range ?? 0...(max(fileSize - 1, 0))
        let length = fileSize == 0 ? 0 : (span.upperBound - span.lowerBound + 1)

        headers.replaceOrAdd(name: "Content-Length", value: "\(length)")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: status.rawValue), headers: headers)))

        if !dropBody, length > 0 {
            // ponytail: streamed in fixed chunks via `FileHandle`, never
            // loads the whole file into memory.
            try fileHandle.seek(toOffset: UInt64(span.lowerBound))
            var remaining = length
            let chunkSize = 65_536
            while remaining > 0, let chunk = try fileHandle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty {
                remaining -= chunk.count
                var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await outbound.write(.body(.byteBuffer(buffer)))
            }
        }
        try await outbound.write(.end(nil))
    }

    // MARK: - WebSocket upgrade

    private func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
        head.headers["Upgrade"].first?.lowercased() == "websocket"
            && head.headers["Connection"].first?.lowercased().contains("upgrade") == true
    }

    private func handleWebSocketUpgrade(head: HTTPRequestHead, rawChannel: Channel) async throws {
        let (path, _) = splitPathAndQuery(head.uri)
        guard let route = app.webSocketRegistry.match(path: path) else {
            try? await rawChannel.close()
            return
        }

        guard let key = head.headers["Sec-WebSocket-Key"].first else {
            try? await rawChannel.close()
            return
        }
        let acceptValue = webSocketAcceptValue(for: key)

        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "Upgrade", value: "websocket")
        responseHeaders.add(name: "Connection", value: "Upgrade")
        responseHeaders.add(name: "Sec-WebSocket-Accept", value: acceptValue)

        let upgradeResponse = HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: responseHeaders)

        // Write the raw 101 response, then strip every HTTP1 handler from the
        // pipeline (in the order they were added) before installing the
        // WebSocket frame codec — from this point the connection speaks the
        // WebSocket framing only, not HTTP/1.1.
        try await writeUpgradeResponse(upgradeResponse, on: rawChannel)
        try await removeHTTPHandlers(from: rawChannel)

        try await rawChannel.pipeline.addHandler(WebSocketFrameEncoder()).get()
        try await rawChannel.pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder())).get()

        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: rawChannel)
        let socket = WebSocket(channel: asyncChannel)
        try? await route.handler(socket)
    }

    // MARK: - WebSocket upgrade wire helpers

    private func writeUpgradeResponse(_ head: HTTPResponseHead, on channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("HTTP/1.1 101 Switching Protocols\r\n")
        for (name, value) in head.headers {
            buffer.writeString("\(name): \(value)\r\n")
        }
        buffer.writeString("\r\n")
        try await channel.writeAndFlush(buffer).get()
    }

    private func removeHTTPHandlers(from channel: Channel) async throws {
        for name in [Self.httpEncoderName, Self.httpDecoderName] {
            if let context = try? await channel.pipeline.context(name: name).get() {
                try? await channel.pipeline.removeHandler(context: context).get()
            }
        }
    }

    private static let httpEncoderName = "SwiftCoreWeb.HTTPResponseEncoder"
    private static let httpDecoderName = "SwiftCoreWeb.HTTPRequestDecoder"

    // MARK: - Bonjour

    private func startBonjour(name: String) {
        let params = NWParameters.tcp
        guard let nwListener = try? NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(app.serverOptions.port))) else {
            serverLogger.error("Failed to start Bonjour advertising")
            return
        }
        nwListener.service = NWListener.Service(name: name, type: "_http._tcp")
        nwListener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                serverLogger.error("Bonjour advertising failed: \(String(describing: error), privacy: .public)")
            }
        }
        nwListener.newConnectionHandler = { connection in
            // This listener exists only to advertise via Bonjour; the real
            // traffic is served by the NIOTS listener bound above on the
            // same port, so any stray connection here is simply cancelled.
            connection.cancel()
        }
        nwListener.start(queue: .global(qos: .utility))
        bonjourListener = nwListener
    }

    // MARK: - Network watchdog rebind

    private func rebindOnNetworkChange() async {
        serverLogger.info("Rebinding listeners after network change")
        for channel in listenerChannelsSnapshot() {
            try? await channel.close()
        }
        do {
            try await bindListeners()
            app.urls = reachableURLs()
            let listeningURLs = app.urls.joined(separator: ", ")
            serverLogger.info("Rebound; now listening on \(listeningURLs, privacy: .public)")
        } catch {
            serverLogger.error("Failed to rebind listeners: \(String(describing: error), privacy: .public)")
        }
    }

    private func listenerChannelsSnapshot() -> [Channel] {
        listenerChannels.withLockedValue { $0 }
    }

    private func reachableURLs() -> [String] {
        var urls = ["http://\(app.serverOptions.host):\(app.serverOptions.port)"]
        if app.tlsOptions != nil {
            urls.append("https://\(app.serverOptions.host):\(app.serverOptions.port + 1)")
        }
        return urls
    }

    // MARK: - Keep awake

    private func applyKeepAwakeIfNeeded() async {
        guard app.keepDeviceAwakeFlag else { return }
        #if canImport(UIKit)
        await MainActor.run {
            let controller = keepAwake ?? KeepAwakeController()
            keepAwake = controller
            controller.applyKeepAwake()
        }
        #endif
    }

    // MARK: - Shutdown

    func stop(timeout: Double) async throws {
        watchdog?.stop()
        bonjourListener?.cancel()

        let channels = listenerChannelsSnapshot()
        for channel in channels {
            try? await channel.close()
        }

        #if canImport(UIKit)
        await MainActor.run { keepAwake?.restoreIdleTimer() }
        #endif

        try? await group.shutdownGracefully()
        app.urls = []
        serverLogger.info("SwiftCoreWeb stopped")
    }
}

enum ServerEngineError: Error {
    case stopped
    case atCapacity
}

// MARK: - Path/query parsing

func splitPathAndQuery(_ uri: String) -> (path: String, query: String?) {
    guard let questionMarkIndex = uri.firstIndex(of: "?") else {
        return (uri, nil)
    }
    let path = String(uri[uri.startIndex..<questionMarkIndex])
    let query = String(uri[uri.index(after: questionMarkIndex)...])
    return (path, query)
}

func parseQueryString(_ raw: String?) -> (query: [String: String], queryAll: [String: [String]]) {
    guard let raw, !raw.isEmpty else { return ([:], [:]) }
    var query: [String: String] = [:]
    var queryAll: [String: [String]] = [:]
    for pair in raw.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawKey = parts.first else { continue }
        let key = (rawKey.removingPercentEncoding ?? String(rawKey)).replacingOccurrences(of: "+", with: " ")
        let rawValue = parts.count > 1 ? String(parts[1]) : ""
        let value = (rawValue.removingPercentEncoding ?? rawValue).replacingOccurrences(of: "+", with: " ")
        query[key] = value
        queryAll[key, default: []].append(value)
    }
    return (query, queryAll)
}

// MARK: - Chunked streaming sink

private struct ChunkedByteSink: AsyncByteSink {
    let outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>

    func write(_ chunk: Data) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
        buffer.writeBytes(chunk)
        try await outbound.write(.body(.byteBuffer(buffer)))
    }
}

// MARK: - TLS identity loading (Security framework, no OpenSSL)

private func loadTLSIdentity(_ options: TlsOptions) throws -> SecIdentity {
    let data: Data
    switch options.p12 {
    case .bundle(let name):
        guard let url = Bundle.main.url(forResource: name, withExtension: "p12") ?? Bundle.main.url(forResource: name, withExtension: nil) else {
            throw ServerEngineError.stopped
        }
        data = try Data(contentsOf: url)
    case .documents(let name):
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        data = try Data(contentsOf: url)
    case .path(let path):
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    }

    guard let password = SecretStore.read(options.passwordKeychainKey) else {
        throw ServerEngineError.stopped
    }

    var items: CFArray?
    let importOptions: [String: Any] = [kSecImportExportPassphrase as String: password]
    let status = SecPKCS12Import(data as CFData, importOptions as CFDictionary, &items)
    guard status == errSecSuccess,
          let dictionaries = items as? [[String: Any]],
          let first = dictionaries.first,
          let identity = first[kSecImportItemIdentity as String] else {
        throw ServerEngineError.stopped
    }
    // Force-cast is safe: `kSecImportItemIdentity` is documented to always
    // be a `SecIdentity` when present in a successful `SecPKCS12Import` result.
    return (identity as! SecIdentity)
}

private func makeTLSOptions(identity: SecIdentity) -> NWProtocolTLS.Options {
    let tlsOptions = NWProtocolTLS.Options()
    guard let secIdentity = sec_identity_create(identity) else {
        return tlsOptions
    }
    sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
    return tlsOptions
}

// MARK: - WebSocket handshake helpers

/// Computes the `Sec-WebSocket-Accept` value per RFC 6455 using CryptoKit's
/// SHA-1 (system framework, no third-party crypto). RFC 6455 mandates SHA-1
/// for this handshake step only; it is not used for any security-sensitive
/// purpose, so `Insecure.SHA1` is the correct, intended API here.
private func webSocketAcceptValue(for key: String) -> String {
    let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
    return Data(digest).base64EncodedString()
}
