import Foundation
import Testing
@testable import VibeKitCore

private func v4(_ port: UInt16, _ address: String = "127.0.0.1") -> PortBinding { PortBinding(port: port, address: address, isIPv6: false) }
private func v6(_ port: UInt16, _ address: String = "::1", acceptsIPv4: Bool? = nil) -> PortBinding {
    PortBinding(port: port, address: address, isIPv6: true, acceptsIPv4: acceptsIPv4)
}

private func server(_ framework: Framework, _ ports: [PortBinding], directory: String? = nil) -> Server {
    Server(id: "s", pid: 1, rootPid: 1, listenerPids: [1], startDate: Date(), ports: ports, framework: framework,
           project: nil, processName: framework.name, executable: "/bin/x", command: "x", directory: directory, launch: nil)
}

@Suite("Primary ports")
struct PortSelectionTests {
    @Test func preferredWebUIPortComesFirst() {
        let ports = PortScanner.orderedPorts([v4(1025), v4(8025)], hints: [], preferred: Framework.mailpit.preferredPorts)
        #expect(ports.map(\.port) == [8025, 1025])
    }

    @Test func preferredPortsKeepTheirOrder() {
        let ports = PortScanner.orderedPorts([v4(9000), v4(9001), v4(1234)], hints: [], preferred: Framework.minio.preferredPorts)
        #expect(ports.map(\.port) == [9001, 9000, 1234])
    }

    @Test func argvHintBeatsPreferredPorts() {
        let ports = PortScanner.orderedPorts([v4(9000), v4(9001)], hints: ["minio", "server", "--port", "9000"],
                                             preferred: Framework.minio.preferredPorts)
        #expect(ports.map(\.port) == [9000, 9001])
    }

    @Test func withoutPreferencesPortsAscend() {
        #expect(PortScanner.orderedPorts([v4(5174), v4(5173)], hints: []).map(\.port) == [5173, 5174])
    }

    @Test func frameworksDeclareTheirWebUIs() {
        #expect(Framework.mailpit.preferredPorts == [8025])
        #expect(Framework.minio.preferredPorts == [9001, 9000])
        #expect(Framework.ngrok.preferredPorts == [4040])
        #expect(Framework.firebase.preferredPorts == [4000])
        #expect(Framework.qdrant.preferredPorts == [6333])
        #expect(Framework.clickhouse.preferredPorts == [8123])
        #expect(Framework.surreal.preferredPorts == [8000])
        #expect(Framework.localstack.preferredPorts == [4566])
        #expect(Framework.rabbitmq.preferredPorts == [15672])
        #expect(Framework.temporal.preferredPorts == [8233])
        #expect(Framework.vite.preferredPorts.isEmpty)
    }
}

@Suite("Port URLs")
struct PortURLTests {
    @Test func everyPortGetsItsOwnURL() {
        let s = server(.mailpit, [v4(8025, "0.0.0.0"), v4(1025)])
        #expect(s.localURL(for: 8025)?.absoluteString == "http://localhost:8025")
        #expect(s.localURL(for: 1025)?.absoluteString == "http://localhost:1025")
    }

    @Test func explicitLoopbackNamesTheAddressFamily() {
        let s = server(.vite, [v4(3000), v6(3001), v6(3002, "::", acceptsIPv4: false), v6(3003, "::", acceptsIPv4: true), v4(3004, "0.0.0.0")])
        #expect(s.localURL(for: 3000, explicitLoopback: true)?.absoluteString == "http://127.0.0.1:3000")
        #expect(s.localURL(for: 3001, explicitLoopback: true)?.absoluteString == "http://[::1]:3001")
        #expect(s.localURL(for: 3002, explicitLoopback: true)?.absoluteString == "http://[::1]:3002")
        #expect(s.localURL(for: 3003, explicitLoopback: true)?.absoluteString == "http://127.0.0.1:3003")
        #expect(s.localURL(for: 3004, explicitLoopback: true)?.absoluteString == "http://127.0.0.1:3004")
        #expect(s.localURL(for: 3001)?.absoluteString == "http://localhost:3001")
        #expect(s.host(for: v4(8080, "192.168.1.5"), explicitLoopback: true) == "192.168.1.5")
        #expect(s.host(for: v6(8080, "fe80::1%en0")) == "[fe80::1%25en0]")
    }

    @Test func secureURL() {
        #expect(server(.vite, [v4(5173)]).localURL(for: 5173, secure: true)?.absoluteString == "https://localhost:5173")
    }

    @Test func connectionStringPortsKeepTheirScheme() {
        let pg = server(.postgres, [v4(5432)])
        #expect(pg.localURL(for: 5432)?.absoluteString == "postgresql://localhost:5432")
        #expect(pg.localURL?.absoluteString == "postgresql://localhost:5432")
    }

    @Test func rabbitMQManagementUIIsHTTPAndAMQPKeepsItsScheme() {
        let ports = PortScanner.orderedPorts([v4(5672), v4(15672)], hints: [], preferred: Framework.rabbitmq.preferredPorts)
        let s = server(.rabbitmq, ports)
        #expect(s.primaryPort == 15672)
        #expect(s.localURL?.absoluteString == "http://localhost:15672")
        #expect(s.localURL(for: 5672)?.absoluteString == "amqp://localhost:5672")
    }

    @Test func noURLForPlainListeners() {
        #expect(server(.stripe, [v4(1234)]).localURL(for: 1234) == nil)
        #expect(server(.tool, [v4(1234)]).localURL == nil)
    }

    @Test func browserAndDirectoryChecks() {
        #expect(server(.vite, [v4(5173)]).canOpenInBrowser)
        #expect(server(.mailpit, [v4(8025)]).canOpenInBrowser)
        #expect(!server(.postgres, [v4(5432)]).canOpenInBrowser)
        #expect(!server(.app, [v4(5000)]).canOpenInBrowser)
        #expect(server(.vite, [v4(5173)]).directoryExists)
        #expect(server(.vite, [v4(5173)], directory: NSTemporaryDirectory()).directoryExists)
        #expect(!server(.vite, [v4(5173)], directory: "/nonexistent/\(UUID().uuidString)").directoryExists)
    }

    @Test func newFieldsDefaultToNil() {
        let s = server(.vite, [v4(5173)])
        #expect(s.launcher == nil)
        #expect(s.containerName == nil)
    }
}
