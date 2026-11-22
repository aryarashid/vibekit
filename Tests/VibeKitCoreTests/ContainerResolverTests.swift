import Darwin
import Foundation
import Testing
@testable import VibeKitCore

private let sampleJSON = """
[
  {
    "Id": "8dfafdbc3a40aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "Names": ["/shop-db-1"],
    "Image": "postgres:16-alpine",
    "State": "running",
    "Labels": {
      "com.docker.compose.project": "shop",
      "com.docker.compose.service": "db",
      "com.docker.compose.project.working_dir": "/Users/dev/code/shop"
    },
    "Ports": [
      {"IP": "0.0.0.0", "PrivatePort": 5432, "PublicPort": 5433, "Type": "tcp"},
      {"IP": "::", "PrivatePort": 5432, "PublicPort": 5433, "Type": "tcp"}
    ]
  },
  {
    "Id": "9e1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "Names": ["/shop-mail-1"],
    "Image": "axllent/mailpit:latest",
    "State": "running",
    "Labels": null,
    "Ports": [
      {"IP": "0.0.0.0", "PrivatePort": 1025, "PublicPort": 1025, "Type": "tcp"},
      {"IP": "0.0.0.0", "PrivatePort": 8025, "PublicPort": 18025, "Type": "tcp"},
      {"PrivatePort": 9999, "Type": "tcp"},
      {"IP": "0.0.0.0", "PrivatePort": 53, "PublicPort": 1053, "Type": "udp"}
    ]
  },
  {
    "Id": "a0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "Names": ["/supabase-studio"],
    "Image": "supabase/studio:20240101",
    "State": "running",
    "Labels": {"com.docker.compose.service": "studio"},
    "Ports": [{"IP": "127.0.0.1", "PrivatePort": 3000, "PublicPort": 54323, "Type": "tcp"}]
  },
  {
    "Id": "b0dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "Names": ["/old-redis"],
    "Image": "redis:7",
    "State": "exited",
    "Ports": []
  }
]
"""

private func runtime(_ ports: [UInt16], framework: Framework = .orbstack) -> Server {
    var server = Server(
        id: "runtime", pid: 700, rootPid: 690, listenerPids: [700], startDate: Date(timeIntervalSince1970: 1_000),
        ports: ports.map { PortBinding(port: $0, address: "*", isIPv6: false) }, framework: framework, project: nil,
        processName: "OrbStack Helper", executable: "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper",
        command: "OrbStack Helper", directory: nil, launch: nil, launcher: "launchd")
    server.cpu = 3
    server.memory = 42
    return server
}

private func containers() throws -> [DockerContainer] {
    try #require(ContainerResolver.decode(Data(sampleJSON.utf8)))
}

@Suite("Containers")
struct ContainerResolverTests {
    @Test func decodesTheEngineAPI() throws {
        let list = try containers()
        #expect(list.count == 4)
        #expect(list[0].name == "shop-db-1")
        #expect(list[0].composeProject == "shop")
        #expect(list[0].composeService == "db")
        #expect(list[0].composeDirectory == "/Users/dev/code/shop")
        #expect(list[1].labels.isEmpty)
        #expect(list[1].ports[2].publicPort == nil)
        #expect(list[3].labels.isEmpty)
    }

    @Test func unpacksPublishedPortsIntoServers() throws {
        let host = runtime([5433, 1025, 18025, 54323, 8080])
        let servers = ContainerResolver.unpack(containers: try containers(), hostServer: host)
        #expect(servers.count == 3)  // The exited container is skipped.

        let db = try #require(servers.first { $0.containerName == "shop-db-1" })
        #expect(db.framework == .postgres)
        #expect(db.ports.count == 1)  // IPv4 and IPv6 entries for one port become one binding.
        #expect(db.primaryPort == 5433)
        #expect(db.localURL?.absoluteString == "postgresql://localhost:5433")
        #expect(db.id == "container-8dfafdbc3a40")
        #expect(db.pid == 700 && db.rootPid == 690)
        #expect(db.launch == nil)
        #expect(db.directory == "/Users/dev/code/shop")
        #expect(db.title == "PostgreSQL")
        #expect(db.detail == "shop-db-1")

        let mail = try #require(servers.first { $0.containerName == "shop-mail-1" })
        #expect(mail.framework == .mailpit)
        // The web UI, published as 18025, comes first even though 8025 is its port inside the container.
        #expect(mail.ports.map(\.port) == [18025, 1025])

        let studio = try #require(servers.first { $0.containerName == "supabase-studio" })
        #expect(studio.framework == .orbstack)
        #expect(studio.title == "supabase-studio")
        #expect(studio.host == "127.0.0.1" || studio.host == "localhost")
        #expect(studio.localURL?.absoluteString == "http://localhost:54323")
    }

    @Test func portsTheRuntimeDoesNotHoldAreSkipped() throws {
        let servers = ContainerResolver.unpack(containers: try containers(), hostServer: runtime([5433]))
        #expect(servers.map(\.containerName) == ["shop-db-1"])
    }

    @Test func resolveReplacesTheRuntimeAndKeepsItsUnclaimedPorts() throws {
        let vite = Server(id: "vite", pid: 10, rootPid: 9, listenerPids: [10], startDate: Date(),
                          ports: [PortBinding(port: 5173, address: "::1", isIPv6: true)], framework: .vite, project: nil,
                          processName: "vite", executable: "/bin/node", command: "vite", directory: nil, launch: nil)
        let resolved = ContainerResolver.resolve(servers: [vite, runtime([5433, 8080])], containers: try containers())
        #expect(resolved.map(\.id) == ["vite", "container-8dfafdbc3a40", "runtime"])
        let rest = try #require(resolved.last)
        #expect(rest.ports.map(\.port) == [8080])
        #expect(rest.cpu == 3 && rest.memory == 42)
        #expect(rest.launcher == "launchd")

        // A runtime whose every port belongs to a container leaves no entry of its own.
        let all = ContainerResolver.resolve(servers: [runtime([5433])], containers: try containers())
        #expect(all.map(\.id) == ["container-8dfafdbc3a40"])

        // Resolving twice changes nothing more.
        #expect(ContainerResolver.resolve(servers: all, containers: try containers()).map(\.id) == all.map(\.id))
    }

    @Test func resolveWithoutARuntimeOpensNoSocket() {
        let vite = Server(id: "vite", pid: 10, rootPid: 9, listenerPids: [10], startDate: Date(), ports: [], framework: .vite,
                          project: nil, processName: "vite", executable: "/bin/node", command: "vite", directory: nil, launch: nil)
        #expect(ContainerResolver.resolve(servers: [vite], home: "/nonexistent").map(\.id) == ["vite"])
    }

    @Test func imagesMapToFrameworks() {
        func framework(_ image: String, service: String? = nil, name: String = "c") -> Framework {
            let labels = service.map { ["com.docker.compose.service": $0] } ?? [:]
            return ContainerResolver.framework(for: DockerContainer(id: "x", names: ["/\(name)"], image: image, labels: labels, ports: []),
                                               fallback: .docker)
        }
        #expect(framework("postgres:16") == .postgres)
        #expect(framework("supabase/postgres:15.1.0.147") == .postgres)
        #expect(framework("postgis/postgis:16-3.4") == .postgres)
        #expect(framework("bitnami/postgresql") == .postgres)
        #expect(framework("ghcr.io/acme/redis:7@sha256:abc") == .redis)
        #expect(framework("redis/redis-stack-server") == .redis)
        #expect(framework("mongo") == .mongo)
        #expect(framework("mysql:8") == .mysql)
        #expect(framework("mariadb:11") == .mariadb)
        #expect(framework("minio/minio") == .minio)
        #expect(framework("qdrant/qdrant") == .qdrant)
        #expect(framework("clickhouse/clickhouse-server:24") == .clickhouse)
        #expect(framework("getmeili/meilisearch:v1.8") == .meilisearch)
        #expect(framework("typesense/typesense:27.0") == .typesense)
        #expect(framework("rabbitmq:3-management") == .rabbitmq)
        #expect(framework("nats:2") == .nats)
        #expect(framework("localstack/localstack") == .localstack)
        #expect(framework("axllent/mailpit") == .mailpit)
        #expect(framework("temporalio/auto-setup:1.24") == .temporal)
        // Web apps named after a database are not the database.
        #expect(framework("postgrest/postgrest") == .docker)
        #expect(framework("rediscommander/redis-commander") == .docker)
        #expect(framework("redis/redisinsight") == .docker)
        #expect(framework("supabase/studio") == .docker)
        #expect(framework("kong:2.8") == .docker)
        // With an unknown image, the compose service decides.
        #expect(framework("acme/custom-db:1", service: "postgres") == .postgres)
        #expect(framework("acme/app:1", service: "web") == .docker)
    }

    @Test func socketPathsPreferDockerHostThenOrbStack() {
        let paths = ContainerResolver.socketPaths(home: "/Users/dev", environment: ["DOCKER_HOST": "unix:///tmp/custom.sock"])
        #expect(paths == ["/tmp/custom.sock", "/Users/dev/.orbstack/run/docker.sock", "/var/run/docker.sock", "/Users/dev/.docker/run/docker.sock"])
        #expect(ContainerResolver.socketPaths(home: "/Users/dev", environment: ["DOCKER_HOST": "tcp://1.2.3.4:2375"]).count == 3)
    }

    @Test func parsesRawResponses() throws {
        let plain = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n\(sampleJSON)".utf8)
        #expect(ContainerResolver.parseResponse(plain)?.count == 4)

        let body = Array(sampleJSON.utf8)
        let mid = body.count / 2
        var chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        chunked += Data(String(mid, radix: 16).utf8) + Data("\r\n".utf8) + Data(body[..<mid]) + Data("\r\n".utf8)
        chunked += Data(String(body.count - mid, radix: 16).utf8) + Data("\r\n".utf8) + Data(body[mid...]) + Data("\r\n0\r\n\r\n".utf8)
        #expect(ContainerResolver.parseResponse(chunked)?.count == 4)

        #expect(ContainerResolver.parseResponse(Data("HTTP/1.0 500 Internal Server Error\r\n\r\n[]".utf8)) == nil)
        #expect(ContainerResolver.parseResponse(Data("garbage".utf8)) == nil)
        // Malformed chunk sizes (negative hex, missing CRLF, truncated stream) must never crash.
        #expect(ContainerResolver.parseResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n[]\r\n0\r\n\r\n".utf8)) == nil)
        #expect(ContainerResolver.parseResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n[]XX0\r\n\r\n".utf8)) == nil)
        #expect(ContainerResolver.parseResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n[]\r\n".utf8)) == nil)
    }

    @Test func remappedWebUIPortGetsHTTPAndCanOpenInBrowser() throws {
        let rabbit = DockerContainer(
            id: "cc11111111111111111111111111111111111111111111111111111111111111",
            names: ["/queue"],
            image: "rabbitmq:3-management",
            ports: [
                .init(ip: "0.0.0.0", privatePort: 5672, publicPort: 15672),
                .init(ip: "0.0.0.0", privatePort: 15672, publicPort: 25672),
            ]
        )
        let unpacked = try #require(ContainerResolver.unpack(containers: [rabbit], hostServer: runtime([15672, 25672])).first)
        #expect(unpacked.framework == .rabbitmq)
        #expect(unpacked.primaryPort == 25672)
        #expect(unpacked.localURL?.absoluteString == "http://localhost:25672")
        #expect(unpacked.localURL(for: 15672)?.absoluteString == "amqp://localhost:15672")
        #expect(unpacked.canOpenInBrowser)
        #expect(unpacked.isContainerControlled)
        #expect(runtime([5432]).isContainerControlled)
    }

    @Test func talksToAUnixSocket() throws {
        let path = "/tmp/vk-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let listener = try FakeEngine(path: path, response: "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n\(sampleJSON)")
        defer { listener.stop() }
        let response = try #require(ContainerResolver.request(socketPath: path, path: "/containers/json", timeout: 1))
        #expect(ContainerResolver.parseResponse(response)?.count == 4)
        #expect(listener.receivedRequest.hasPrefix("GET /containers/json HTTP/1.0\r\nHost: localhost\r\n\r\n"))
    }

    @Test func aSilentSocketTimesOut() throws {
        let path = "/tmp/vk-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let listener = try FakeEngine(path: path, response: nil)
        defer { listener.stop() }
        let start = Date()
        #expect(ContainerResolver.request(socketPath: path, path: "/containers/json", timeout: 0.2) == nil)
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func aMissingSocketFailsFast() {
        #expect(ContainerResolver.request(socketPath: "/tmp/vk-missing-\(UUID().uuidString.prefix(8)).sock", path: "/", timeout: 0.2) == nil)
        #expect(ContainerResolver.request(socketPath: "/tmp/" + String(repeating: "x", count: 200), path: "/", timeout: 0.2) == nil)
    }
}

/// A one-connection Unix socket server that answers with `response`, or holds the connection open when it is nil.
private final class FakeEngine: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var request = ""
    private var stopped = false

    var receivedRequest: String { lock.withLock { request } }

    init(path: String, response: String?) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        let fd = self.fd
        Thread.detachNewThread { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if n > 0 { lock.withLock { request = String(decoding: buffer[..<n], as: UTF8.self) } }
            if let response {
                let out = Array(response.utf8)
                _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            } else {
                // Hold the connection until the test ends.
                while !lock.withLock({ stopped }) { usleep(20_000) }
                close(client)
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        close(fd)
    }
}
