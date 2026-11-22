import Darwin
import Foundation

/// One container from the Docker Engine API's `GET /containers/json`.
public struct DockerContainer: Hashable, Sendable, Decodable {
    public struct PublishedPort: Hashable, Sendable, Decodable {
        /// The host address, such as `0.0.0.0`, `::` or `127.0.0.1`. Absent for a port that is not published.
        public let ip: String?
        public let privatePort: UInt16
        public let publicPort: UInt16?
        public let type: String

        public init(ip: String?, privatePort: UInt16, publicPort: UInt16?, type: String = "tcp") {
            self.ip = ip
            self.privatePort = privatePort
            self.publicPort = publicPort
            self.type = type
        }

        enum CodingKeys: String, CodingKey {
            case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type"
        }
    }

    public let id: String
    public let names: [String]
    public let image: String
    public let state: String
    public let labels: [String: String]
    public let ports: [PublishedPort]

    public init(id: String, names: [String], image: String, state: String = "running",
                labels: [String: String] = [:], ports: [PublishedPort]) {
        self.id = id
        self.names = names
        self.image = image
        self.state = state
        self.labels = labels
        self.ports = ports
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", labels = "Labels", ports = "Ports"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        ports = try c.decodeIfPresent([PublishedPort].self, forKey: .ports) ?? []
    }

    /// The container's name without the leading slash the API adds, such as `shop-db-1`.
    public var name: String {
        let raw = names.first ?? String(id.prefix(12))
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var composeService: String? { labels["com.docker.compose.service"] }
    /// The folder `docker compose up` ran in.
    public var composeDirectory: String? { labels["com.docker.compose.project.working_dir"] }
}

/// Splits the Docker or OrbStack listener on this Mac into one entry per container, so `5432` reads as PostgreSQL in
/// `shop-db-1` instead of one more port of "OrbStack".
///
/// It asks the Docker Engine API over its Unix socket, without starting a process. Call it only while someone is
/// looking (the panel is open, or `--list` runs), never from the idle scan, and off the main thread: an unresponsive
/// socket can take up to the timeout.
public enum ContainerResolver {
    /// Where Docker-compatible runtimes put their socket, OrbStack first. `DOCKER_HOST` comes before all of them.
    public static func socketPaths(home: String = NSHomeDirectory(),
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") { paths.append(String(host.dropFirst(7))) }
        paths += [home + "/.orbstack/run/docker.sock", "/var/run/docker.sock", home + "/.docker/run/docker.sock"]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// `servers` with each Docker or OrbStack listener replaced by its containers' published ports. The runtime keeps
    /// an entry of its own only for ports no container claims. With no runtime listener, or no reachable socket,
    /// `servers` comes back unchanged and no socket is opened.
    public static func resolve(servers: [Server], home: String = NSHomeDirectory(), timeout: TimeInterval = 0.25) -> [Server] {
        guard servers.contains(where: isRuntime) else { return servers }
        guard let containers = fetchContainers(home: home, timeout: timeout) else { return servers }
        return resolve(servers: servers, containers: containers)
    }

    /// The pure half of `resolve(servers:)`.
    public static func resolve(servers: [Server], containers: [DockerContainer]) -> [Server] {
        var result: [Server] = []
        for server in servers {
            guard isRuntime(server) else {
                result.append(server)
                continue
            }
            let unpacked = unpack(containers: containers, hostServer: server)
            let claimed = Set(unpacked.flatMap { $0.ports.map(\.port) })
            result += unpacked
            let remaining = server.ports.filter { !claimed.contains($0.port) }
            if !remaining.isEmpty { result.append(remaining.count == server.ports.count ? server : server.replacingPorts(remaining)) }
        }
        return result
    }

    static func isRuntime(_ server: Server) -> Bool {
        server.containerName == nil && (server.framework.id == Framework.docker.id || server.framework.id == Framework.orbstack.id)
    }

    /// One server per running container that publishes a TCP port `hostServer` listens on.
    ///
    /// Each entry keeps the runtime's `pid` and `rootPid`, since that is the process holding the port on this Mac, and
    /// has `containerName` set and no `launch`: stopping or restarting it as a process would take down every container.
    public static func unpack(containers: [DockerContainer], hostServer: Server) -> [Server] {
        let hostPorts = Set(hostServer.ports.map(\.port))
        var servers: [Server] = []
        for container in containers where container.state.isEmpty || container.state == "running" {
            let published = container.ports.filter { $0.type == "tcp" && $0.publicPort.map(hostPorts.contains) == true }
            guard !published.isEmpty else { continue }
            let framework = framework(for: container, fallback: hostServer.framework)
            let bindings = published.compactMap { port -> PortBinding? in
                guard let publicPort = port.publicPort else { return nil }
                let ip = port.ip ?? "0.0.0.0"
                let isIPv6 = ip.contains(":")
                return PortBinding(port: publicPort, address: ip, isIPv6: isIPv6, acceptsIPv4: !isIPv6)
            }
            // Preferred ports name the container's own ports; the host may publish them under other numbers.
            let preferred = framework.preferredPorts.flatMap { inside in
                published.filter { $0.privatePort == inside }.compactMap(\.publicPort)
            }
            let ports = PortScanner.orderedPorts(bindings, hints: [], preferred: preferred)
            var server = Server(
                id: "container-\(container.id.prefix(12))",
                pid: hostServer.pid,
                rootPid: hostServer.rootPid,
                listenerPids: hostServer.listenerPids,
                startDate: hostServer.startDate,
                ports: ports,
                framework: framework,
                project: nil,
                processName: container.name,
                executable: hostServer.executable,
                command: container.image,
                directory: container.composeDirectory,
                launch: nil,
                launcher: hostServer.framework.name,
                containerName: container.name,
                webUIPorts: Set(preferred)
            )
            server.processCount = 0
            servers.append(server)
        }
        return servers.sorted { ($0.primaryPort, $0.id) < ($1.primaryPort, $1.id) }
    }

    // MARK: Images

    private static let imageFrameworks: [String: Framework] = [
        "postgres": .postgres, "postgresql": .postgres, "postgis": .postgres, "timescaledb": .postgres, "pgvector": .postgres,
        "mysql": .mysql, "mariadb": .mariadb, "mongo": .mongo, "mongodb": .mongo,
        "redis": .redis, "valkey": .valkey, "memcached": .memcached,
        "mailpit": .mailpit, "mailhog": .mailpit, "minio": .minio, "qdrant": .qdrant, "clickhouse": .clickhouse,
        "meilisearch": .meilisearch, "typesense": .typesense, "rabbitmq": .rabbitmq, "nats": .nats,
        "localstack": .localstack, "elasticsearch": .elasticsearch, "opensearch": .opensearch, "surrealdb": .surreal,
        "cockroach": .cockroach, "influxdb": .influx, "etcd": .etcd, "ollama": .ollama, "inngest": .inngest,
        "litellm": .litellm, "vllm": .vllm, "temporal": .temporal, "caddy": .caddy,
    ]
    private static let namespaceFrameworks: [String: Framework] = ["temporalio": .temporal]

    /// Admin and monitoring images that carry a database's name but are web apps, such as `redis-commander`.
    private static let toolWords: Set<String> = [
        "admin", "commander", "insight", "ui", "studio", "exporter", "dashboard", "web", "console", "proxy", "rest",
    ]

    /// What a container runs, from its image, then its compose service, then its name. Web apps with no database
    /// image, such as Supabase Studio or Kong, keep the runtime's framework.
    public static func framework(for container: DockerContainer, fallback: Framework) -> Framework {
        let repository = imageRepository(container.image)
        if let match = match(repository.name) { return match }
        if isTool(repository.name) { return fallback }
        // Vendors whose image names say what part they are, not what product, such as `temporalio/auto-setup`.
        if let match = namespaceFrameworks[repository.namespace] { return match }
        for candidate in [container.composeService, container.name].compactMap({ $0 }) {
            if let match = match(candidate) { return match }
        }
        return fallback
    }

    /// `ghcr.io/acme/postgres:16-alpine` becomes namespace `acme`, name `postgres`.
    static func imageRepository(_ image: String) -> (namespace: String, name: String) {
        var reference = image.lowercased()
        if let at = reference.firstIndex(of: "@") { reference = String(reference[..<at]) }
        var parts = reference.split(separator: "/").map(String.init)
        if var last = parts.popLast() {
            if let colon = last.firstIndex(of: ":") { last = String(last[..<colon]) }
            return (parts.last ?? "", last)
        }
        return ("", "")
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { "-_.".contains($0) }).map(String.init)
    }

    private static func isTool(_ text: String) -> Bool { words(text).contains(where: toolWords.contains) }

    private static func match(_ text: String) -> Framework? {
        if let exact = imageFrameworks[text.lowercased()] { return exact }
        guard !isTool(text) else { return nil }
        // `clickhouse-server`, `vllm-openai`, `shop-db-postgres-1`: the first word that names one.
        return words(text).lazy.compactMap { imageFrameworks[$0] }.first
    }

    // MARK: Engine API

    /// Containers from the first runtime socket that answers, or nil when none does.
    public static func fetchContainers(home: String = NSHomeDirectory(), timeout: TimeInterval = 0.25) -> [DockerContainer]? {
        for path in socketPaths(home: home) where FileManager.default.fileExists(atPath: path) {
            guard let response = request(socketPath: path, path: "/containers/json", timeout: timeout) else { continue }
            if let containers = parseResponse(response) { return containers }
        }
        return nil
    }

    /// The containers in a raw HTTP response, or nil unless it is a 200 with a JSON array.
    static func parseResponse(_ response: Data) -> [DockerContainer]? {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/"), status.split(separator: " ").dropFirst().first == "200" else {
            return nil
        }
        var body = Data(response[split.upperBound...])
        let chunked = lines.dropFirst().contains {
            $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked")
        }
        if chunked {
            guard let decoded = dechunk(body) else { return nil }
            body = decoded
        }
        return decode(body)
    }

    /// Containers in a `/containers/json` body.
    public static func decode(_ json: Data) -> [DockerContainer]? {
        try? JSONDecoder().decode([DockerContainer].self, from: json)
    }

    static func dechunk(_ data: Data) -> Data? {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.allSatisfy(\.isHexDigit),
                  let size = Int(sizeText, radix: 16), size >= 0 else { return nil }
            if size == 0 { return output }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(start, offsetBy: size)
            let next = data.index(end, offsetBy: 2)
            guard data[end..<next] == crlf else { return nil }
            output.append(data[start..<end])
            index = next
        }
        return nil
    }

    /// One HTTP/1.0 GET over a Unix socket. HTTP/1.0 makes the server close the connection after the body.
    static func request(socketPath: String, path: String, timeout: TimeInterval, limit: Int = 8 << 20) -> Data? {
        var address = sockaddr_un()
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        // A runtime that quits mid-request must not kill Vibe Kit with SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let seconds = max(timeout, 0.01)
        var interval = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard connected else { return nil }

        let request = Array("GET \(path) HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            let n = request[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            sent += n
        }

        let deadline = Date().addingTimeInterval(seconds)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return response }
            guard n > 0 else { return nil }  // Timed out or failed: a partial body is no answer.
            response.append(contentsOf: buffer[..<n])
            if response.count > limit { return nil }
        }
        return nil
    }
}
