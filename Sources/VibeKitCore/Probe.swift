import Darwin
import Foundation

/// What a dev server answered on `/`.
public struct PageInfo: Hashable, Sendable {
    public let status: Int
    public let title: String?
    /// Answered over HTTPS only, so links to it must use `https://`.
    public let isSecure: Bool

    public init(status: Int, title: String?, isSecure: Bool = false) {
        self.status = status
        self.title = title
        self.isSecure = isSecure
    }
}

/// Fetches `/` once per server for its status and `<title>`.
/// One request per server lifetime: frameworks like Next.js compile on every request, so polling would cost CPU.
public enum Probe {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "VibeKit", "Accept": "text/html,*/*;q=0.8"]
        return URLSession(configuration: config, delegate: LocalOnly(), delegateQueue: nil)
    }()

    /// Asks over HTTP, then over HTTPS when the server dropped or garbled the plain HTTP request. A timeout or a
    /// refused connection is not tried again: a server still compiling would log a TLS handshake it cannot read.
    public static func page(host: String = "localhost", port: UInt16) async -> PageInfo? {
        switch await attempt(scheme: "http", host: host, port: port) {
        case .success(let page): return page
        case .failure(let error) where [.timedOut, .cannotConnectToHost, .cancelled].contains(error.code): return nil
        case .failure: return try? await attempt(scheme: "https", host: host, port: port).get()
        }
    }

    static func page(scheme: String, host: String, port: UInt16) async -> PageInfo? {
        try? await attempt(scheme: scheme, host: host, port: port).get()
    }

    private static func attempt(scheme: String, host: String, port: UInt16) async -> Result<PageInfo, URLError> {
        guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { return .failure(URLError(.badURL)) }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { return .failure(URLError(.badServerResponse)) }
            var data = Data()
            let isHTML = (http.value(forHTTPHeaderField: "Content-Type") ?? "").localizedCaseInsensitiveContains("html")
            if isHTML {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 128 * 1024 { break }
                    // Stop as soon as the title has arrived.
                    if byte == UInt8(ascii: ">"), data.count > 16, data.suffix(8) == Data("</title>".utf8) { break }
                }
            }
            bytes.task.cancel()
            return .success(PageInfo(status: http.statusCode, title: isHTML ? title(in: data) : nil, isSecure: scheme == "https"))
        } catch let error as URLError {
            return .failure(error)
        } catch {
            return .failure(URLError(.unknown))
        }
    }

    /// Requests stay on this Mac. A redirect, such as to a sign-in page, is the answer itself: following it would
    /// contact another site and report that site's status and title as the dev server's.
    /// Local HTTPS servers use certificates made for development, so their certificate is accepted, for hosts on this Mac
    /// only: loopback, or one of this Mac's own addresses when a server listening on the network is probed there.
    private final class LocalOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
                  Probe.isLocal(space.host) else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    /// `ownAddresses` lists this Mac's interface addresses. Any other host, including other machines on the same
    /// private network, is not local.
    static func isLocal(_ host: String, ownAddresses: () -> [String] = Network.localAddresses) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" || bare.hasPrefix("127.") || bare == "::1" { return true }
        // Only a literal IPv4 address can be one of ours. A name could resolve anywhere.
        var parsed = in_addr()
        guard inet_pton(AF_INET, bare, &parsed) == 1 else { return false }
        return ownAddresses().contains(bare)
    }

    static func title(in data: Data) -> String? {
        let html = String(decoding: data, as: UTF8.self)
        var search = html.startIndex..<html.endIndex
        var contentStart: String.Index?
        while let open = html.range(of: "<title", options: .caseInsensitive, range: search) {
            let after = open.upperBound
            guard after < html.endIndex else { break }
            let next = html[after]
            // Reject tags like <titlebar> that only share a prefix.
            if next == ">" || next.isWhitespace {
                if let close = html.range(of: ">", range: after..<html.endIndex) {
                    contentStart = close.upperBound
                }
                break
            }
            search = after..<html.endIndex
        }
        guard let start = contentStart,
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start..<html.endIndex)
        else { return nil }
        let raw = html[start..<end.lowerBound]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Decode `&amp;` last so `&amp;lt;` becomes `&lt;`, not `<`.
        let decoded = raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return decoded.isEmpty ? nil : decoded
    }
}

public enum Network {
    /// True when nothing holds `port`. Tries to bind it on IPv4 and IPv6, which also catches root-owned
    /// listeners the scan cannot see.
    public static func isPortFree(_ port: UInt16) -> Bool {
        canBindIPv4(port) && canBindIPv6(port)
    }

    private static func canBindIPv4(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }  // Cannot tell, so do not claim someone holds it.
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Only "address in use" means a listener has it. Other errors say nothing about the port.
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 || errno != EADDRINUSE
            }
        }
    }

    private static func canBindIPv6(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }  // No IPv6 here, so nothing can listen on it.
        defer { close(fd) }
        var only: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 || errno != EADDRINUSE
            }
        }
    }

    /// The Mac's address on the local network, for opening a dev server from a phone.
    public static func lanAddress() -> String? {
        let candidates = ipv4Interfaces().filter { entry in
            !["utun", "awdl", "llw", "bridge", "anpi", "ap"].contains(where: entry.name.hasPrefix) && !entry.address.hasPrefix("169.254.")
        }
        // The interface the default route uses, when it is one of these: with Ethernet and Wi-Fi both up,
        // that is the network the phone is most likely on.
        if let routed = defaultRouteAddress(), candidates.contains(where: { $0.address == routed }) { return routed }
        // Otherwise prefer Wi-Fi and Ethernet (en0, en1...) over VPN and virtual interfaces.
        return candidates.sorted { $0.name < $1.name }.first { $0.name.hasPrefix("en") }?.address ?? candidates.first?.address
    }

    /// Every IPv4 address this Mac holds on an interface that is up, loopback aside, including VPN and bridge interfaces.
    public static func localAddresses() -> [String] {
        ipv4Interfaces().map(\.address)
    }

    private static func ipv4Interfaces() -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append((String(cString: entry.ifa_name), address))
        }
        return result
    }

    /// The source address the system picks for traffic to the internet. A UDP connect sends no packets.
    private static func defaultRouteAddress() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(53).bigEndian
        remote.sin_addr = in_addr(s_addr: inet_addr("192.0.2.1"))  // TEST-NET-1: routed like the internet, never answered.
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        guard named else { return nil }
        return LibProc.ipv4String(local.sin_addr)
    }
}
