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
    private struct Lifecycle {
        var rebinding = false
        var rebindRequested = false
        var stopping = false
        var finished = false
    }
    private let lifecycle = NIOLockedValueBox(Lifecycle())
    /// Completed when the engine has ended (by `stop` or because its listeners went away): what `run()` waits on.
    private let finished: EventLoopPromise<Void>
    /// Completed when the first `stop()` has fully finished (listeners closed, group shut down).
    private let stopped: EventLoopPromise<Void>
    private var bonjourListener: NWListener?
    #if canImport(UIKit)
    // ponytail: KeepAwakeController is @MainActor (touches UIApplication);
    // ServerEngine's init is not, so construction is deferred to first use
    // on the main actor (applyKeepAwakeIfNeeded) instead of a stored default.
    private var keepAwake: KeepAwakeController?
    #endif
    private var previousIdleTimerApplied = false
    private let group: NIOTSEventLoopGroup
    /// Random per run; only extensions receive it (through `RequestIngress.peer`).
    private let peerSecret = ServerEngine.makeSecret()
    private let peerPort = NIOLockedValueBox<Int?>(nil)
    /// Bound once and kept for the engine's whole life: it is loopback, so a network change does not touch it, and the
    /// extensions hold its port.
    private let peerChannel = NIOLockedValueBox<Channel?>(nil)

    /// Bytes ever appended to an in-memory request-body buffer: stays 0 for spooled routes
    /// (the memory-bound test asserts on it, not on process RSS).
    let bufferedBodyBytes = NIOLockedValueBox(0)
    /// Test seam: told about every spool file the moment it is created.
    var onSpoolCreated: (@Sendable (URL) -> Void)?

    private init(app: WebApplication) throws {
        self.app = app
        self.dispatcher = try app.makeDispatcher()
        self.rateLimiter = app.rateLimitOptions.map(RateLimiter.init)
        self.connectionGate = ConnectionGate(maxConcurrent: app.serverOptions.maxConcurrentConnections)
        self.group = NIOTSEventLoopGroup()
        self.finished = group.next().makePromise(of: Void.self)
        self.stopped = group.next().makePromise(of: Void.self)
    }

    /// Builds, binds, and runs the engine for `app`, suspending until
    /// `stop(timeout:)` is called. Registers itself on `app.engineBox` (so
    /// `stopAsync()` can reach it) only once the listeners are bound, and
    /// unregisters as soon as it ends for any reason (a failed bind, a
    /// listener closed by the OS), not only through `stopAsync()`: that keeps
    /// `isRunning` equal to "listening" instead of "an engine was created".
    static func start(for app: WebApplication) async throws {
        UploadStorage.sweepStale()
        let engine = try ServerEngine(app: app)
        defer { app.engineBox.clear(ifCurrent: engine) }
        try await engine.run()
    }

    private func run() async throws {
        await applyKeepAwakeIfNeeded()

        do {
            try await bindListeners()
        } catch {
            // Undo what was set up before the bind (keep-awake, event loop group); the caller sees the bind error.
            try? await stop(timeout: 0)
            throw error
        }
        do {
            try await bindPeerListener()
        } catch {
            try? await stop(timeout: 0) // also closes the HTTP listener(s) that were already bound
            throw error
        }
        // Extensions start before the engine registers (`isRunning`), so a `stopAsync()` cannot land mid-start.
        do {
            let ingress = RequestIngress(
                dispatcher: dispatcher, rateLimiter: rateLimiter, connectionGate: connectionGate,
                webSocketRegistry: app.webSocketRegistry, metrics: app.metrics, port: listenerChannelsSnapshot().first?.localAddress?.port ?? app.serverOptions.port,
                peer: peerPort.withLockedValue { $0 }.map { PeerEndpoint(port: $0, secret: peerSecret) }
            )
            for serverExtension in app.extensions { try await serverExtension.start(ingress: ingress) }
        } catch {
            try? await stop(timeout: 0)
            throw error
        }
        app.engineBox.engine = self

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
        app.metrics.markStarted()
        let listeningURLs = app.urls.joined(separator: ", ")
        serverLogger.info("SwiftCoreWeb listening on \(listeningURLs, privacy: .public)")

        // Suspend until the engine ends: `stop()`, or the OS closing a listener (a network rebind does not count).
        try await finished.futureResult.get()
        // Listeners that went away without `stop()`: release what the engine and its extensions still hold.
        try? await stop(timeout: 0)
    }

    private func finish() {
        let first = lifecycle.withLockedValue { state -> Bool in
            let already = state.finished
            state.finished = true
            return !already
        }
        if first { finished.succeed(()) }
    }

    private func listenerClosed() {
        let unexpected = lifecycle.withLockedValue { !$0.stopping && !$0.rebinding }
        if unexpected { finish() }
    }

    // MARK: - Binding

    /// Extensions that forward traffic get a loopback listener that reads the peer's identity (see `PeerPreambleDecoder`).
    private func bindPeerListener() async throws {
        guard !app.extensions.isEmpty else { return }
        let channel = try await makeBootstrap(tls: false, peer: true).bind(host: "127.0.0.1", port: 0).get()
        peerChannel.withLockedValue { $0 = channel }
        peerPort.withLockedValue { $0 = channel.localAddress?.port }
    }

    private func bindListeners() async throws {
        var bound: [Channel] = []
        do {
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
        } catch {
            // A listener that did bind must not outlive a failed pair: nothing else would ever close it.
            for channel in bound { try? await channel.close() }
            throw error
        }

        listenerChannels.withLockedValue { $0 = bound }
        for channel in bound {
            channel.closeFuture.whenComplete { [weak self] _ in self?.listenerClosed() }
        }
    }

    private func makeBootstrap(tls: Bool, tlsOptions: TlsOptions? = nil, peer: Bool = false) -> NIOTSListenerBootstrap {
        var bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ServerEngineError.stopped)
                }
                return self.configureChildChannel(channel, peer: peer)
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

    private func configureChildChannel(_ channel: Channel, peer: Bool = false) -> EventLoopFuture<Void> {
        let remoteIP = channel.remoteAddress?.ipAddress ?? "unknown"
        let promise = channel.eventLoop.makePromise(of: Void.self)

        // Hop to the `ConnectionGate` actor to reserve a slot, then continue
        // pipeline setup back on the channel's event loop. No blocking:
        // `configureChildChannel` returns the pending future immediately.
        Task { [weak self] in
            guard let self else { promise.fail(ServerEngineError.stopped); return }
            guard await self.connectionGate.tryAcquire() else {
                channel.close(promise: nil)
                self.app.metrics.recordRejected(.atCapacity)
                promise.fail(ServerEngineError.atCapacity)
                return
            }
            self.app.metrics.connectionOpened()
            channel.eventLoop.execute {
                (peer ? self.setUpPeerPipeline(channel) : self.setUpHTTPPipeline(channel, remoteIP: remoteIP, fromPeer: false)).cascade(to: promise)
            }
        }

        return promise.futureResult
    }

    /// A connection to the peer listener: reads the identity line first, then serves HTTP as usual with that identity as the
    /// client address. A bad or missing line closes the connection and gives back the slot taken for it.
    private func setUpPeerPipeline(_ channel: Channel) -> EventLoopFuture<Void> {
        let identity = channel.eventLoop.makePromise(of: String.self)
        identity.futureResult.whenFailure { [weak self] _ in
            guard let self else { return }
            self.app.metrics.connectionClosed()
            Task { await self.connectionGate.release() }
        }
        do {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(PeerPreambleDecoder(secret: peerSecret, promise: identity)))
        } catch {
            identity.fail(error)
            return channel.eventLoop.makeFailedFuture(error)
        }
        // The channel only starts reading once its initializer has finished, so this must not wait for the identity line:
        // the HTTP handlers are added when the line arrives.
        identity.futureResult.flatMap { [weak self] remoteIP -> EventLoopFuture<Void> in
            guard let self else { return channel.eventLoop.makeFailedFuture(ServerEngineError.stopped) }
            return self.setUpHTTPPipeline(channel, remoteIP: remoteIP, fromPeer: true).flatMapError { error in
                // The identity was fine but serving could not start: give back the slot taken for this connection.
                self.app.metrics.connectionClosed()
                Task { await self.connectionGate.release() }
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.whenFailure { _ in channel.close(promise: nil) }
        return channel.eventLoop.makeSucceededVoidFuture()
    }

    /// Adds the named HTTP1 handlers (WebSocket upgrade removes them by
    /// these names) and starts serving the connection. Runs on the channel's
    /// own event loop, after `ConnectionGate` has reserved a slot.
    private func setUpHTTPPipeline(_ channel: Channel, remoteIP: String, fromPeer: Bool) -> EventLoopFuture<Void> {
        // Synchronous (we are on the channel's loop): the peer path relies on the handlers being in place at once.
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder(), name: Self.httpEncoderName)
            try channel.pipeline.syncOperations.addHandler(
                ByteToMessageHandler(HTTPRequestDecoder()),
                name: Self.httpDecoderName
            )
        }.flatMapThrowing { [weak self] in
            guard let self else { throw ServerEngineError.stopped }
            let asyncChannel = try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                wrappingChannelSynchronously: channel
            )
            Task {
                defer {
                    self.app.metrics.connectionClosed()
                    Task { await self.connectionGate.release() }
                }
                await self.serve(asyncChannel, remoteIP: remoteIP, fromPeer: fromPeer, rawChannel: channel)
            }
        }
    }

    // MARK: - Per-connection serving

    private func serve(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        remoteIP: String,
        fromPeer: Bool,
        rawChannel: Channel
    ) async {
        var rateLimited = false
        if let rateLimiter, await !rateLimiter.allow(clientIP: remoteIP) {
            app.metrics.recordRejected(.rateLimited)
            rateLimited = true
        }

        do {
            try await channel.executeThenClose { inbound, outbound in
                var requestHead: HTTPRequestHead?
                var bodyBuffer = ByteBuffer()
                var maxBodySize = app.serverOptions.maxRequestBodySize
                // Set while the body of a `spoolBodyToDisk` route is being written to its file.
                // Every way out of this closure (413, disconnect, shutdown, error) discards a
                // spool that was not handed to the dispatcher, which deletes the file itself.
                var spool: BodySpool?
                var hiddenFromPeer = false
                defer { spool?.discard() }

                // An early rejection (413, 429) is sent with `Connection: close`, then the rest of the
                // request is read and thrown away (bounded in bytes and time) before the connection
                // closes: closing while the client is still sending makes it see a reset, not the status.
                var rejected = false
                var discarded = 0
                var closer: Scheduled<Void>?
                defer { closer?.cancel() }
                func reject(_ status: HTTPResponseStatus, _ extra: [(String, String)] = []) async throws {
                    try await writeSimpleResponse(outbound, status: status, extraHeaders: extra + [("Connection", "close")])
                    rejected = true
                    closer = rawChannel.eventLoop.scheduleTask(in: .seconds(Self.rejectDrainSeconds)) { rawChannel.close(promise: nil) }
                }
                if rateLimited { try await reject(.tooManyRequests, [("Retry-After", "1")]) }

                for try await part in inbound {
                    if rejected {
                        if case .body(let chunk) = part { discarded += chunk.readableBytes }
                        if case .end = part { return }
                        if discarded > Self.rejectDrainBytes { return }
                        continue
                    }
                    switch part {
                    case .head(let head):
                        requestHead = head
                        bodyBuffer.clear()
                        spool?.discard()
                        spool = nil
                        // A path kept from peers is handled as one that matches nothing, body limits included.
                        hiddenFromPeer = fromPeer && !dispatcher.router.peerAccess.allows(path: splitPathAndQuery(head.uri).path)
                        // A route (or group) may override the global limit and ask for the body on
                        // disk; resolved from the head alone, so an oversized body is cut off
                        // before it is buffered.
                        let plan = hiddenFromPeer
                            ? (limit: app.serverOptions.maxRequestBodySize, spool: false)
                            : dispatcher.bodyPlan(
                                method: HttpMethod(rawValue: head.method.rawValue) ?? .get,
                                path: splitPathAndQuery(head.uri).path,
                                contentLength: head.headers.first(name: "Content-Length").flatMap { Int($0) }
                            )
                        maxBodySize = plan.limit
                        if plan.spool {
                            do {
                                let created = try BodySpool()
                                spool = created
                                onSpoolCreated?(created.url)
                            } catch {
                                try await reject(.insufficientStorage)
                            }
                        }

                    case .body(var chunk):
                        if let current = spool {
                            do { try current.write(&chunk) } catch {
                                current.discard()
                                spool = nil
                                try await reject(.insufficientStorage)
                                continue
                            }
                            if current.written > maxBodySize {
                                current.discard() // the partial file goes away with the rejected request
                                spool = nil
                                try await reject(.payloadTooLarge)
                            }
                            continue
                        }
                        bufferedBodyBytes.withLockedValue { $0 += chunk.readableBytes }
                        bodyBuffer.writeBuffer(&chunk)
                        if bodyBuffer.readableBytes > maxBodySize {
                            bodyBuffer = ByteBuffer() // free what was buffered; nothing more is kept
                            try await reject(.payloadTooLarge)
                        }

                    case .end:
                        guard let head = requestHead else { continue }

                        if !hiddenFromPeer, isWebSocketUpgrade(head) {
                            try await handleWebSocketUpgrade(head: head, rawChannel: rawChannel, remoteIP: remoteIP, outbound: outbound)
                            return
                        }

                        let bodyFile = spool?.finish()
                        spool = nil // the dispatcher deletes the file once the response is produced
                        let request = makeHttpRequest(head: head, body: bodyBuffer, remoteAddress: remoteIP, bodyFile: bodyFile)
                        let response = await dispatcher.dispatch(request, hidden: hiddenFromPeer)
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

    /// How much of a rejected request's body is read and discarded, and for how long, before closing.
    private static let rejectDrainBytes = 64 * 1024 * 1024
    private static let rejectDrainSeconds: Int64 = 5

    private func writeSimpleResponse(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        status: HTTPResponseStatus,
        extraHeaders: [(String, String)] = []
    ) async throws {
        let headers = HTTPHeaders([("Content-Length", "0")] + extraHeaders)
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.end(nil))
    }

    private func makeHttpRequest(head: HTTPRequestHead, body: ByteBuffer, remoteAddress: String, bodyFile: URL? = nil) -> HttpRequest {
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
            body: bodyData,
            bodyFile: bodyFile
        )
    }

    private func write(
        _ response: HttpResponse,
        method: HTTPMethod,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        defer { response.onSent?() }
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
            // A known `Content-Length` (Results.stream(contentLength:)) is kept; otherwise chunked.
            if !headers.contains(name: "Content-Length") {
                headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            }
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

    private func handleWebSocketUpgrade(
        head: HTTPRequestHead,
        rawChannel: Channel,
        remoteIP: String,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let (path, _) = splitPathAndQuery(head.uri)
        guard let route = app.webSocketRegistry.match(path: path) else {
            try? await rawChannel.close()
            return
        }

        guard let key = head.headers["Sec-WebSocket-Key"].first else {
            try? await rawChannel.close()
            return
        }

        // The route's `auth` is enforced here, before the 101: once upgraded, the HTTP pipeline is gone.
        if case .none = route.auth {} else {
            let request = makeHttpRequest(head: head, body: ByteBuffer(), remoteAddress: remoteIP)
            if let denied = await dispatcher.authorizeUpgrade(request, auth: route.auth) {
                try await write(denied, method: head.method, to: outbound)
                return
            }
        }
        let acceptValue = webSocketAcceptValue(for: key)

        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "Upgrade", value: "websocket")
        responseHeaders.add(name: "Connection", value: "Upgrade")
        responseHeaders.add(name: "Sec-WebSocket-Accept", value: acceptValue)

        let upgradeResponse = HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: responseHeaders)

        // The 101 goes through the HTTP encoder; the connection then speaks WebSocket frames only, through `WebSocketBridge`.
        let socket = try await WebSocketBridge.upgrade(
            rawChannel, response: upgradeResponse, removing: [Self.httpEncoderName, Self.httpDecoderName]
        )
        app.metrics.webSocketOpened()
        defer { app.metrics.webSocketClosed() }
        try? await route.handler(socket)
        try? await socket.close() // a handler that just returns still says goodbye (1000) before the connection drops
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

    func rebindOnNetworkChange() async {
        // One rebind at a time; a change that arrives meanwhile is applied right after, not lost.
        let mayStart = lifecycle.withLockedValue { state -> Bool in
            if state.stopping { return false }
            if state.rebinding { state.rebindRequested = true; return false }
            state.rebinding = true
            return true
        }
        guard mayStart else { return }
        repeat {
            app.metrics.recordRebind()
            serverLogger.info("Rebinding listeners after network change")
            for channel in listenerChannelsSnapshot() {
                try? await channel.close()
            }
            do {
                // The port of a listener that was just closed can take a moment to be free again.
                var attempt = 0
                while true {
                    do { try await bindListeners(); break } catch {
                        attempt += 1
                        guard attempt < 5, !lifecycle.withLockedValue({ $0.stopping }) else { throw error }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                if lifecycle.withLockedValue({ $0.stopping }) { break }
                app.urls = reachableURLs()
                let listeningURLs = app.urls.joined(separator: ", ")
                serverLogger.info("Rebound; now listening on \(listeningURLs, privacy: .public)")
            } catch {
                // Not listening for now; the next network change tries again.
                listenerChannels.withLockedValue { $0 = [] }
                app.urls = []
                serverLogger.error("Failed to rebind listeners: \(String(describing: error), privacy: .public)")
            }
        } while lifecycle.withLockedValue({ state -> Bool in
            if state.rebindRequested && !state.stopping {
                state.rebindRequested = false
                return true
            }
            state.rebinding = false
            return false
        })
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
        let first = lifecycle.withLockedValue { state -> Bool in
            let already = state.stopping
            state.stopping = true
            return !already
        }
        guard first else {
            // Someone else is already stopping: return when that has finished, so the port is really free.
            try? await stopped.futureResult.get()
            return
        }
        defer {
            finish()
            stopped.succeed(())
        }
        for serverExtension in app.extensions { await serverExtension.stop() }
        watchdog?.stop()
        bonjourListener?.cancel()

        let channels = listenerChannelsSnapshot()
        for channel in channels {
            try? await channel.close()
        }
        if let peer = peerChannel.withLockedValue({ $0.take() }) { try? await peer.close() }
        peerPort.withLockedValue { $0 = nil }

        #if canImport(UIKit)
        await MainActor.run { keepAwake?.restoreIdleTimer() }
        #endif

        try? await group.shutdownGracefully()
        app.urls = []
        app.metrics.markStopped()
        serverLogger.info("SwiftCoreWeb stopped")
    }
}

extension ServerEngine {
    static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }).map { String(format: "%02x", $0) }.joined()
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
