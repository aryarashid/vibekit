import AppKit
import SwiftUI
import Vision
import XCTest
@testable import VibeKit

@MainActor
final class QRCodeTests: XCTestCase {
    func testRenderedCodeDecodesToNetworkAddressInBothAppearances() throws {
        _ = NSApplication.shared
        let address = "http://192.168.1.24:8000"
        let host = NSHostingView(rootView: QRCodeView(text: address).frame(width: 170, height: 170))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: 0, width: 170, height: 170),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: XCTUnwrap(rep.cgImage)).perform([request])
            XCTAssertEqual(request.results?.compactMap(\.payloadStringValue), [address])
        }
    }
}
