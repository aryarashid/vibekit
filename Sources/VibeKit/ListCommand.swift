import Foundation
import VibeKitCore

/// `VibeKit --list [--all]`: the same scan as the menu, printed as a table.
enum ListCommand {
    static func run(all: Bool) {
        let scanner = PortScanner()
        _ = scanner.scan(usageFor: [])
        usleep(300_000)
        let servers = scanner.scan(usageFor: Set(ServerCategory.allCases), fullSweep: true)
            .filter { all || $0.category != .other }
            .sorted { ($0.category.rawValue, $0.primaryPort) < ($1.category.rawValue, $1.primaryPort) }

        if servers.isEmpty {
            print("No dev servers running.")
            return
        }
        let rows = servers.map { server in
            [String(server.primaryPort), server.title, server.framework.name, server.project?.branch ?? "",
             String(server.rootPid), String(format: "%.1f%%", server.cpu), "\(server.memory / 1_048_576) MB"]
        }
        let header = ["PORT", "NAME", "KIND", "BRANCH", "PID", "CPU", "MEM"]
        let widths = header.indices.map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }
        for row in [header] + rows {
            print(row.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  "))
        }
    }
}
