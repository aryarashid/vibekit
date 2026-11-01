import Darwin
import Foundation
import VibeKitCore

/// `VibeKit --bench [seconds] [--open]`: runs the scan loop headless and reports CPU cost per scan.
/// With `--open` it uses the cadence and categories of an open panel.
enum Bench {
    static func run(seconds: Int, panelOpen: Bool) {
        let scanner = PortScanner()
        let categories: Set<ServerCategory> = panelOpen ? Set(ServerCategory.allCases) : [.dev, .database, .service]
        let interval = panelOpen ? 1.5 : 4
        func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
        let start = cpu()
        var worst: UInt64 = 0
        var ticks = 0
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < end {
            let before = cpu()
            _ = scanner.scan(usageFor: categories)
            let spent = cpu() - before
            worst = max(worst, spent)
            ticks += 1
            Thread.sleep(forTimeInterval: interval)
        }
        let total = Double(cpu() - start) / 1e6
        print(String(format: "%@: %d scans, %.2f ms CPU per scan on average, worst %.2f ms, %.3f%% of one core",
                     panelOpen ? "panel open" : "panel closed", ticks, total / Double(ticks), Double(worst) / 1e6,
                     total / Double(seconds * 1000) * 100))
        print(scanner.stats)
    }
}
