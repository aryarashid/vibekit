import Foundation
import Testing
@testable import VibeKitCore

/// Probes against real local servers, run by the system Python.
@Suite("Probing local servers", .serialized)
struct ProbeServerTests {
    /// Starts a Python server from `script` on a free port and returns the process and port.
    private func serve(_ script: String) async throws -> (Process, UInt16) {
        var port: UInt16 = 0
        repeat { port = UInt16.random(in: 20_000...40_000) } while !Network.isPortFree(port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<50 where Network.isPortFree(port) { try await Task.sleep(for: .milliseconds(100)) }
        return (process, port)
    }

    @Test func aRedirectIsTheAnswerAndIsNotFollowed() async throws {
        let (server, port) = try await serve("""
        import sys, http.server
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302); self.send_header("Location", "http://example.invalid/login"); self.end_headers()
            def log_message(self, *a): pass
        http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
        """)
        defer { server.terminate() }
        let page = await Probe.page(host: "127.0.0.1", port: port)
        #expect(page?.status == 302)
        #expect(page?.isSecure == false)
    }

    @Test func anHTTPSOnlyServerWithADevelopmentCertificateAnswers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vk-tls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                             "-keyout", dir.appendingPathComponent("key.pem").path, "-out", dir.appendingPathComponent("cert.pem").path]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        let (server, port) = try await serve("""
        import sys, ssl, http.server
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b"<html><title>Secure App</title></html>"
                self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(body)
            def log_message(self, *a): pass
        s = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("\(dir.path)/cert.pem", "\(dir.path)/key.pem")
        s.socket = c.wrap_socket(s.socket, server_side=True)
        s.serve_forever()
        """)
        defer { server.terminate() }
        let page = await Probe.page(host: "127.0.0.1", port: port)
        #expect(page?.status == 200)
        #expect(page?.title == "Secure App")
        #expect(page?.isSecure == true)
    }
}
