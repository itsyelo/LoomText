//
//  LoomDynamicColorTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import LoomText

@MainActor
final class LoomDynamicColorTests: XCTestCase {

    /// Trait propagation requires a window: `overrideUserInterfaceStyle`
    /// on a detached view does not update its own `traitCollection`.
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.isHidden = false
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    /// Red in light mode, green in dark mode — unambiguous per-pixel.
    /// The provider MUST be @Sendable: the async pipeline resolves
    /// dynamic colors on a render thread, and Swift 6 would otherwise
    /// infer MainActor isolation from the test class and trap at
    /// resolution time. The same rule applies to library users.
    private var dynamicColor: UIColor {
        UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? .green : .red
        }
    }

    private func text(_ string: String = "Dynamic") -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: dynamicColor,
        ])
    }

    private func displayedContents(_ label: LoomLabel, timeout: TimeInterval = 2) -> CGImage? {
        label.layer.setNeedsDisplay()
        label.layer.displayIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while label.layer.contents == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return label.layer.contents.map { $0 as! CGImage }
    }

    /// Dominant ink channel of the rendered image: (red, green) pixel counts.
    private func inkChannels(_ image: CGImage) -> (red: Int, green: Int) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0, green = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 24 {
            if data[i] > data[i + 1] { red += 1 } else if data[i + 1] > data[i] { green += 1 }
        }
        return (red, green)
    }

    private func makeLabel(style: UIUserInterfaceStyle, async: Bool) -> LoomLabel {
        let size = CGSize(width: 160, height: 40)
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = style
        window.addSubview(label)
        label.displaysAsynchronously = async
        label.textLayout = LoomTextLayout(containerSize: size, text: text())
        return label
    }

    func testDynamicColorResolvesLightSync() throws {
        let contents = try XCTUnwrap(displayedContents(makeLabel(style: .light, async: false)))
        let channels = inkChannels(contents)
        XCTAssertGreaterThan(channels.red, 50)
        XCTAssertEqual(channels.green, 0)
    }

    func testDynamicColorResolvesDarkSync() throws {
        let contents = try XCTUnwrap(displayedContents(makeLabel(style: .dark, async: false)))
        let channels = inkChannels(contents)
        XCTAssertGreaterThan(channels.green, 50)
        XCTAssertEqual(channels.red, 0)
    }

    func testDynamicColorResolvesDarkAsync() throws {
        // The background render queue has no ambient dark traits — only
        // the captured performAsCurrent can produce green here.
        let contents = try XCTUnwrap(displayedContents(makeLabel(style: .dark, async: true)))
        let channels = inkChannels(contents)
        XCTAssertGreaterThan(channels.green, 50)
        XCTAssertEqual(channels.red, 0)
    }

    func testAppearanceFlipRedisplaysWithNewColors() throws {
        let label = makeLabel(style: .light, async: true)
        var channels = inkChannels(try XCTUnwrap(displayedContents(label)))
        XCTAssertGreaterThan(channels.red, 50)

        window.overrideUserInterfaceStyle = .dark
        // Trait registration marks the layer dirty; pump until the new
        // appearance lands.
        let deadline = Date().addingTimeInterval(2)
        repeat {
            label.layer.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            channels = inkChannels(try XCTUnwrap(displayedContents(label)))
        } while channels.green == 0 && Date() < deadline

        XCTAssertGreaterThan(channels.green, 50, "appearance flip must re-render with dark colors")
        XCTAssertEqual(channels.red, 0)
    }
}
#endif
