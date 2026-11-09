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

    /// Asks over HTTP, then over HTTPS when the server did not answer plain HTTP.
    public static func page(host: String = "localhost", port: UInt16) async -> PageInfo? {
        if let page = await page(scheme: "http", host: host, port: port) { return page }
        return await page(scheme: "https", host: host, port: port)
    }

    static func page(scheme: String, host: String, port: UInt16) async -> PageInfo? {
        guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { return nil }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { return nil }
            var data = Data()
            let isHTML = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html")
            if isHTML {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 128 * 1024 { break }
                    // Stop as soon as the title has arrived.
                    if byte == UInt8(ascii: ">"), data.count > 16, data.suffix(8) == Data("</title>".utf8) { break }
                }
            }
            bytes.task.cancel()
            return PageInfo(status: http.statusCode, title: isHTML ? title(in: data) : nil, isSecure: scheme == "https")
        } catch {
            return nil
        }
    }

    /// Requests stay on this Mac. A redirect, such as to a sign-in page, is the answer itself: following it would
    /// contact another site and report that site's status and title as the dev server's.
    /// Local HTTPS servers use certificates made for development, so their certificate is accepted, for local hosts only.
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

    static func isLocal(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare.hasPrefix("127.") || bare == "::1"
    }

    static func title(in data: Data) -> String? {
        let html = String(decoding: data, as: UTF8.self)
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<html.endIndex)
        else { return nil }
        let raw = html[close.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
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
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
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
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }

    /// The Mac's address on the local network, for opening a dev server from a phone.
    public static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            if ["utun", "awdl", "llw", "bridge", "anpi", "ap"].contains(where: name.hasPrefix) { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if address.hasPrefix("169.254.") { continue }
            candidates.append((name, address))
        }
        // Prefer Wi-Fi and Ethernet (en0, en1...) over VPN and virtual interfaces.
        return candidates.sorted { $0.name < $1.name }.first { $0.name.hasPrefix("en") }?.address ?? candidates.first?.address
    }
}
