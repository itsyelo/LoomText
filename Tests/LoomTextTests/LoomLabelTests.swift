//
//  LoomLabelTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import LoomText

/// UIKit-dependent label tests — run via the iOS Simulator job.
@MainActor
final class LoomLabelTests: XCTestCase {

    private func attr(_ string: String, size: CGFloat = 16) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black]
        )
    }

    /// Displays the label through its (a)sync layer pipeline and returns
    /// the committed contents.
    private func displayedContents(_ label: LoomLabel, timeout: TimeInterval = 2) -> CGImage? {
        label.layer.setNeedsDisplay()
        label.layer.displayIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while label.layer.contents == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let contents = label.layer.contents else { return nil }
        return (contents as! CGImage)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func inkCount(_ image: CGImage) -> Int {
        let bytes = rgba(image)
        return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] > 24 ? 1 : 0) }
    }

    // MARK: - Modes

    func testDirectModeRendersInk() throws {
        let size = CGSize(width: 200, height: 40)
        let layout = LoomTextLayout(containerSize: size, text: attr("Direct mode"))
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = layout
        XCTAssertEqual(label.intrinsicContentSize, layout?.textBoundingSize)

        let contents = try XCTUnwrap(displayedContents(label))
        XCTAssertGreaterThan(inkCount(contents), 20)
    }

    func testConvenienceMatchesDirectPixelForPixel() throws {
        let size = CGSize(width: 180, height: 120)
        let text = attr("Convenience and direct modes must agree, pixel for pixel. 两种模式逐像素一致")

        let direct = LoomLabel(frame: CGRect(origin: .zero, size: size))
        direct.displaysAsynchronously = false
        direct.textLayout = LoomTextLayout(containerSize: size, text: text)

        let convenience = LoomLabel(frame: CGRect(origin: .zero, size: size))
        convenience.displaysAsynchronously = false
        convenience.attributedText = text
        convenience.layoutIfNeeded()

        let directBytes = rgba(try XCTUnwrap(displayedContents(direct)))
        let convenienceBytes = rgba(try XCTUnwrap(displayedContents(convenience)))
        XCTAssertEqual(directBytes, convenienceBytes)
    }

    func testConvenienceModeRespectsNumberOfLines() {
        let size = CGSize(width: 100, height: 500)
        let text = attr("A reasonably long sentence that will definitely wrap across many lines here")
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.numberOfLines = 2
        label.attributedText = text
        label.layoutIfNeeded()
        XCTAssertEqual(label.textLayout?.rowCount, 2)
        XCTAssertEqual(label.textLayout?.isTruncated, true)
    }

    func testAssigningLayoutSwitchesOutOfConvenienceMode() {
        let size = CGSize(width: 150, height: 60)
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.attributedText = attr("convenience first")
        label.layoutIfNeeded()

        let direct = LoomTextLayout(containerSize: size, text: attr("now direct"))
        label.textLayout = direct
        label.layoutIfNeeded()
        XCTAssertTrue(label.textLayout === direct)
        XCTAssertEqual(label.attributedText?.string, "now direct")
    }

    func testSizeThatFitsMeasuresConvenienceText() {
        let label = LoomLabel(frame: .zero)
        label.attributedText = attr("Measure me")
        let fitted = label.sizeThatFits(CGSize(width: 300, height: 100))
        XCTAssertGreaterThan(fitted.width, 0)
        XCTAssertGreaterThan(fitted.height, 0)
        XCTAssertLessThan(fitted.width, 300)
    }

    // MARK: - Async pipeline

    func testAsyncMatchesSyncPixelForPixel() throws {
        let size = CGSize(width: 180, height: 90)
        let text = attr("Async and sync rendering agree byte for byte 异步同步一致")

        let sync = LoomLabel(frame: CGRect(origin: .zero, size: size))
        sync.displaysAsynchronously = false
        sync.textLayout = LoomTextLayout(containerSize: size, text: text)

        let async = LoomLabel(frame: CGRect(origin: .zero, size: size))
        async.displaysAsynchronously = true
        async.textLayout = LoomTextLayout(containerSize: size, text: text)

        let syncBytes = rgba(try XCTUnwrap(displayedContents(sync)))
        let asyncBytes = rgba(try XCTUnwrap(displayedContents(async)))
        XCTAssertEqual(syncBytes, asyncBytes)
    }

    func testRapidReassignmentConvergesToLastLayout() throws {
        let size = CGSize(width: 180, height: 90)
        let first = attr("FIRST layout with plenty of text to draw across the label")
        let last = attr("LAST")

        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = true
        label.textLayout = LoomTextLayout(containerSize: size, text: first)
        label.layer.displayIfNeeded() // submit render of `first`
        label.textLayout = LoomTextLayout(containerSize: size, text: last) // cancels it
        let contents = try XCTUnwrap(displayedContents(label))

        let reference = LoomLabel(frame: CGRect(origin: .zero, size: size))
        reference.displaysAsynchronously = false
        reference.textLayout = LoomTextLayout(containerSize: size, text: last)
        let referenceContents = try XCTUnwrap(displayedContents(reference))

        XCTAssertEqual(rgba(contents), rgba(referenceContents), "stale render must never win")
    }

    func testNilLayoutClearsContents() throws {
        let size = CGSize(width: 120, height: 40)
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: size, text: attr("soon gone"))
        _ = try XCTUnwrap(displayedContents(label))

        label.textLayout = nil
        label.layer.displayIfNeeded()
        XCTAssertNil(label.layer.contents)
    }
}
#endif
