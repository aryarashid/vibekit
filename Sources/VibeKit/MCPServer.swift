import CoreFoundation
import Foundation
import VibeKitCore

/// One request per line on stdio. Nothing creates a server or runs a tool during GUI startup.
struct MCPServer {
    typealias Handler = @Sendable (ServerAction) async throws -> CommandOutput
    let allowControl: Bool
    let handler: Handler

    init(allowControl: Bool = false, handler: @escaping Handler = { try await ListCommand().run($0, format: .mcp) }) {
        self.allowControl = allowControl
        self.handler = handler
    }

    func run() async {
        while let line = readLine() {
            if let reply = await handleRequest(Data(line.utf8)) { FileHandle.standardOutput.write(reply + Data([10])) }
        }
    }

    private struct RPCError: Error {
        let code: Int
        let message: String
        init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    }

    func handleRequest(_ data: Data) async -> Data? {
        var id: Any = NSNull()
        func response(_ key: String, _ value: Any) -> Data? {
            try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, key: value], options: [.withoutEscapingSlashes])
        }
        do {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
            catch { throw RPCError(-32700, "Parse error") }
            guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
                  let method = request["method"] as? String else { throw RPCError(-32600, "Invalid request") }
            // Notifications get no response and must never dispatch a control action.
            guard let requestID = request["id"] else { return nil }
            guard requestID is String || Self.integer(requestID) != nil else { throw RPCError(-32600, "Invalid request ID") }
            id = requestID
            let params = request["params"] as? [String: Any] ?? [:]
            guard request["params"] == nil || request["params"] is [String: Any] else { throw RPCError(-32602, "Expected an object for params") }
            switch method {
            case "initialize":
                let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
                let requested = params["protocolVersion"] as? String ?? ""
                return response("result", ["protocolVersion": versions.contains(requested) ? requested : versions[0],
                                           "capabilities": ["tools": [String: Any]()],
                                           "serverInfo": ["name": "VibeKit", "version": CLIArguments.versionString]])
            case "ping": return response("result", [String: Any]())
            case "tools/list":
                return response("result", ["tools": Tool.allCases.filter { allowControl || !$0.control }.map(\.schema)])
            case "tools/call":
                guard let name = params["name"] as? String, let tool = Tool(rawValue: name) else { throw RPCError(-32602, "Unknown tool") }
                guard !tool.control || allowControl else { throw RPCError(-32602, "\(name) requires --allow-control") }
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else { throw RPCError(-32602, "Expected an arguments object") }
                let action = try tool.action(params["arguments"] as? [String: Any] ?? [:])
                do {
                    let output = try await handler(action)
                    return response("result", ["content": [["type": "text", "text": output.text]]])
                } catch {
                    return response("result", ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
                }
            default: throw RPCError(-32601, "Method not found")
            }
        } catch let error as RPCError {
            return response("error", ["code": error.code, "message": error.message])
        } catch { return response("error", ["code": -32603, "message": "Internal error"]) }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    private enum Tool: String, CaseIterable {
        case list = "list_servers", port = "check_port", probe = "probe_server", logs = "read_server_logs"
        case prompts = "list_prompts", stop = "stop_server", restart = "restart_server"

        var control: Bool { self == .stop || self == .restart }
        var description: String {
            switch self {
            case .list: "List local servers, optionally including other listeners and sampled CPU usage."
            case .port: "Check port availability and ownership, or find the next free port."
            case .probe: "Read the HTTP status, title and HTTPS indicator from a server."
            case .logs: "Read the last lines of a server's recorded log without terminal escapes."
            case .prompts: "Search saved prompts by title and text, in library order."
            case .stop: "Stop a server by port, PID or project/title."
            case .restart: "Restart a server by port, PID or project/title and capture its output."
            }
        }

        enum Field: String {
            case includeOther = "include_other", includeCPU = "include_cpu", port, nextFree = "next_free", host, target
            case tail = "tail_lines", query

            var type: String {
                switch self {
                case .includeOther, .includeCPU, .nextFree: "boolean"
                case .port, .tail: "integer"
                default: "string"
                }
            }
            var required: Bool { self == .port || self == .target }
            var schema: [String: Any] {
                var schema: [String: Any] = ["type": type]
                switch self {
                case .port: schema["minimum"] = 1; schema["maximum"] = 65535
                case .tail: schema["minimum"] = 0
                case .target, .host: schema["minLength"] = 1
                default: break
                }
                return schema
            }
        }

        var fields: [Field] {
            switch self {
            case .list: [.includeOther, .includeCPU]
            case .port: [.port, .nextFree]
            case .probe: [.port, .host]
            case .logs: [.target, .tail]
            case .prompts: [.query]
            case .stop, .restart: [.target]
            }
        }
        var schema: [String: Any] {
            let properties = Dictionary(uniqueKeysWithValues: fields.map { ($0.rawValue, $0.schema) })
            let input: [String: Any] = ["type": "object", "properties": properties, "required": fields.filter(\.required).map(\.rawValue),
                                        "additionalProperties": false]
            return ["name": rawValue, "description": description, "inputSchema": input]
        }

        func action(_ args: [String: Any]) throws -> ServerAction {
            guard Set(args.keys).isSubset(of: fields.map(\.rawValue)) else { throw RPCError(-32602, "Unexpected argument for \(rawValue)") }
            func string(_ name: Field, default fallback: String? = nil) throws -> String {
                if args[name.rawValue] == nil, let fallback { return fallback }
                guard let value = args[name.rawValue] as? String,
                      name == .query || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RPCError(-32602, "Expected string for \(name.rawValue)")
                }
                return value
            }
            func bool(_ name: Field) throws -> Bool {
                guard let value = args[name.rawValue] else { return false }
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw RPCError(-32602, "Expected boolean for \(name.rawValue)")
                }
                return number.boolValue
            }
            func port() throws -> UInt16 {
                guard let value = MCPServer.integer(args["port"]), let port = UInt16(exactly: value), port > 0 else {
                    throw RPCError(-32602, "Expected port 1–65535")
                }
                return port
            }
            switch self {
            case .list: return try .list(all: bool(.includeOther), cpu: bool(.includeCPU))
            case .port: return try .port(port(), next: bool(.nextFree))
            case .probe:
                var host = try string(.host, default: "localhost")
                if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
                // Require a local host, never remote destinations, URL credentials, paths or an embedded port.
                guard let components = URLComponents(string: "http://\(host)"), components.host?.isEmpty == false,
                      components.port == nil, components.user == nil, components.password == nil,
                      components.path.isEmpty, components.query == nil, components.fragment == nil else { throw RPCError(-32602, "Invalid host") }
                guard Probe.isLocal(host) else { throw RPCError(-32602, "Host must be local") }
                return try .probe(port(), host: host)
            case .logs:
                guard let lines = MCPServer.integer(args["tail_lines"] ?? 50), lines >= 0 else { throw RPCError(-32602, "Expected nonnegative tail_lines") }
                return try .logs(string(.target), tail: lines)
            case .prompts: return try .prompts(string(.query, default: ""))
            case .stop: return try .stop(string(.target))
            case .restart: return try .restart(string(.target))
            }
        }
    }
}
