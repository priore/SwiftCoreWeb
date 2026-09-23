// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation
import UIKit
import SwiftCoreWeb

/// Assembles the minimal demo `WebApplication`: the static page in `www/`
/// (bundled as a resource, like `ShowcaseApp/www`) plus one JSON API route,
/// listening on all interfaces so it is reachable at
/// `http://[device-ip]:8080/` from any device on the same network.
enum HelloWorldServer {
    static func makeApplication() -> WebApplication {
        // `createBuilder()` returns the fluent configuration object; nothing
        // is bound to a socket yet — `.build()` below finalizes it into an
        // actual `WebApplication`, and the app only starts listening once
        // `runAsync()` is called from `HelloWorldRootView`.
        let builder = WebApplication.createBuilder()

        builder.usePort(8080)
        // LAN-reachable, not just loopback — the whole point of this sample
        // is "open http://[device-ip] from another machine". Without this
        // call the server would default to binding 127.0.0.1 only, which a
        // WKWebView on the same device can reach but Chrome/Postman on
        // another machine cannot.
        builder.listenOnAllInterfaces()
        // Keeps the device from auto-locking while the server is serving
        // requests in the foreground (see the framework's
        // NetworkWatchdog/LifecycleSupport design). Not required for the demo
        // to work, but avoids the server going quiet mid-test just because
        // the screen dimmed.
        builder.keepDeviceAwake(true)

        // From here on `app` is the live routing/middleware surface: every
        // `.mapGet`/`.use*` call below registers against the same instance.
        let app = builder.build()

        // The one API route this sample exposes. Returning a plain
        // `Encodable` struct (`DeviceNameResponse`) makes the framework
        // serialize it to JSON with a `200 OK` and
        // `Content-Type: application/json` automatically — no manual
        // response building needed (see `HttpResponse.swift`'s
        // `makeHttpResult`). This is the endpoint to hit directly from
        // Chrome or Postman: `http://<device-ip>:8080/api/device-name`.
        app.mapGet("/api/device-name") { _ in
            DeviceNameResponse(
                // `UIDevice.current` is `@MainActor`-isolated (it touches
                // UIKit state), while this route handler runs off the main
                // actor, so the read has to hop via `MainActor.run`.
                deviceName: await MainActor.run { UIDevice.current.name },
                ipAddress: localIPAddress() ?? "unknown"
            )
        }

        // Built-in Vue 3 runtime (the built-in Vue runtime design): serves
        // /_framework/vue.js (the vendored Vue 3 ESM build, MIT licensed,
        // works fully offline — no CDN/npm/Node involved) and
        // /_framework/api.js (a tiny `fetch` wrapper: `api.get(path)` etc.,
        // used by www/index.html below). Must be registered before
        // `useSpa`, though route order does not actually matter here since
        // the paths never collide.
        app.useVue()

        // Serves www/index.html (and any other file placed under www/) from
        // the app bundle, via the framework's static/SPA hosting (the SPA
        // hosting design) — the same mechanism `ShowcaseServer.swift` uses
        // for its Vue build in release mode
        // (`.useSpa(root: .bundle("dist"))`). `useSpa` additionally falls
        // back to index.html for any unmatched `GET` that isn't under
        // `/api`, so client-side routes (if this page ever grows any) keep
        // working on a hard refresh too.
        app.useSpa(root: .bundle("www"))

        return app
    }
}

/// The JSON payload served at `/api/device-name`. Both fields answer the
/// two things you'd want to confirm when testing from an external client:
/// which device answered, and what address you reached it on.
private struct DeviceNameResponse: Encodable {
    let deviceName: String
    let ipAddress: String
}

/// The device's LAN IPv4 address, read via POSIX `getifaddrs` — no
/// framework/library needed, just the C sockets API Foundation already
/// links against. Lets you point Chrome or Postman at
/// `http://<this>:8080/` from another machine on the same network, without
/// having to dig the IP out of iOS Settings by hand.
///
/// Prefers the known interface names (`en0`/`en1` Wi-Fi, `pdp_ip0`
/// cellular) a real device uses; the Simulator shares the Mac's network
/// under whatever interface currently holds the LAN IP (e.g. `en10` over
/// USB Ethernet, or a different `enN` depending on the Mac's hardware), so
/// this falls back to the first UP, non-loopback, non-link-local IPv4
/// address found when none of the preferred names match.
private func localIPAddress() -> String? {
    // `getifaddrs` fills a linked list of every network interface the
    // system knows about (Wi-Fi, cellular, loopback, VPN tunnels, …), each
    // with its own address family (IPv4, IPv6, link-layer). We only care
    // about IPv4 here since that is what a browser/Postman URL needs.
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return nil }
    // The list is heap-allocated by the C call and must be freed manually
    // once we are done walking it — `defer` guarantees that even if a
    // `guard`/`return` below exits early.
    defer { freeifaddrs(ifaddrPointer) }

    // Walk the linked list (`ifa_next` chains each node to the next) into a
    // Swift array, keeping only IPv4 interfaces that are currently up.
    // `IFF_UP` filters out interfaces the OS knows about but that are
    // administratively down (e.g. an unplugged Ethernet adapter).
    let interfaces = sequence(first: firstAddr, next: { $0.pointee.ifa_next })
        .map { $0.pointee }
        .filter { $0.ifa_addr.pointee.sa_family == UInt8(AF_INET) && ($0.ifa_flags & UInt32(IFF_UP)) != 0 }

    // First choice: the interface names a real device actually uses for
    // Wi-Fi/cellular. On a physical iPhone/iPad this is normally the only
    // match and the fallback below never triggers.
    let preferredNames = ["en0", "en1", "pdp_ip0"]
    let preferred = interfaces.first { preferredNames.contains(String(cString: $0.ifa_name)) }
    // Fallback for the Simulator (and any environment with unfamiliar
    // interface names): take the first non-link-local address. Addresses
    // starting `169.254.` are APIPA/link-local — assigned when there is no
    // real network reachable — and never useful for another machine to
    // connect to, so they're explicitly excluded rather than picked first.
    let fallback = interfaces.first { !ipAddressString(for: $0).hasPrefix("169.254.") }

    guard let match = preferred ?? fallback else { return nil }
    return ipAddressString(for: match)
}

/// Converts one `ifaddrs` entry's raw `sockaddr` into a human-readable
/// dotted-quad string (e.g. `"192.168.1.142"`) via `getnameinfo` with the
/// `NI_NUMERICHOST` flag, which skips any reverse-DNS lookup and just
/// formats the address bytes directly — this needs to stay fast and work
/// offline, so no DNS round-trip is acceptable here.
private func ipAddressString(for interface: ifaddrs) -> String {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    return String(cString: host)
}
