//
//  LoomHighlightTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreText
import XCTest
@testable import LoomText

/// Cross-platform highlight/selection geometry tests.
final class LoomHighlightGeometryTests: XCTestCase {

    private func highlightedText(
        _ string: String,
        highlightRange: NSRange,
        size: CGFloat = 16
    ) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let text = NSMutableAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        text.loom_setHighlight(
            highlightRange,
            pressedAttributes: [.loomTestPressedMarker: true],
            userInfo: ["id": 42]
        )
        return text
    }

    func testHighlightHitAndMiss() throws {
        // "Hello World tail" — highlight on "World".
        let range = NSRange(location: 6, length: 5)
        let text = highlightedText("Hello World tail", highlightRange: range)
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: text)
        )
        let rect = layout.rect(for: range)
        XCTAssertFalse(rect.isNull)

        let hit = try XCTUnwrap(layout.highlight(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(hit.range, range)
        XCTAssertEqual(hit.highlight.userInfo?["id"] as? Int, 42)

        // Before the highlight ("Hello") and outside any line: both miss.
        XCTAssertNil(layout.highlight(at: CGPoint(x: 2, y: rect.midY)))
        XCTAssertNil(layout.highlight(at: CGPoint(x: rect.midX, y: rect.maxY + 100)))
    }

    func testSelectionRectsSingleLine() throws {
        let range = NSRange(location: 6, length: 5)
        let text = highlightedText("Hello World tail", highlightRange: range)
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: text)
        )
        let rects = layout.selectionRects(for: range)
        XCTAssertEqual(rects.count, 1)
        let line = layout.lines[0]
        XCTAssertEqual(rects[0].minY, line.bounds.minY, accuracy: 0.001)
        XCTAssertEqual(rects[0].height, line.bounds.height, accuracy: 0.001)
        XCTAssertGreaterThan(rects[0].minX, 0)
        XCTAssertLessThan(rects[0].maxX, layout.textBoundingSize.width)
    }

    func testSelectionRectsSpanLines() throws {
        let string = "wrap wrap wrap wrap wrap wrap wrap wrap wrap"
        let range = NSRange(location: 10, length: 25)
        let text = highlightedText(string, highlightRange: range)
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 90, height: 10_000), text: text)
        )
        XCTAssertGreaterThan(layout.rowCount, 2)
        let rects = layout.selectionRects(for: range)
        XCTAssertGreaterThan(rects.count, 1)
        for (a, b) in zip(rects, rects.dropFirst()) {
            XCTAssertLessThan(a.minY, b.minY, "rects must descend line by line")
        }
        // Union covers every per-line rect.
        let union = layout.rect(for: range)
        for rect in rects {
            XCTAssertTrue(union.contains(rect))
        }
    }

    func testEmptyRangeYieldsNoRects() throws {
        let text = highlightedText("Hello", highlightRange: NSRange(location: 0, length: 2))
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 100, height: 50), text: text)
        )
        XCTAssertTrue(layout.selectionRects(for: NSRange(location: 1, length: 0)).isEmpty)
        XCTAssertTrue(layout.rect(for: NSRange(location: 1, length: 0)).isNull)
    }
}

extension NSAttributedString.Key {
    static let loomTestPressedMarker = NSAttributedString.Key("LoomTestPressedMarker")
}

#if canImport(UIKit)
import UIKit

/// UIKit pressed-state pipeline tests.
@MainActor
final class LoomHighlightPressedStateTests: XCTestCase {

    private func makeLabel() -> (LoomLabel, NSRange) {
        let size = CGSize(width: 240, height: 40)
        let range = NSRange(location: 4, length: 4)
        let text = NSMutableAttributedString(string: "tap LINK here", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: UIColor.red,
        ])
        text.loom_setHighlight(range, pressedAttributes: [.foregroundColor: UIColor.green])
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: size, text: text)
        return (label, range)
    }

    private func displayedContents(_ label: LoomLabel) -> CGImage? {
        label.layer.displayIfNeeded()
        return label.layer.contents.map { $0 as! CGImage }
    }

    private func greenCount(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var green = 0
        for i in stride(from: 0, to: data.count, by: 4)
        where data[i + 3] > 24 && data[i + 1] > data[i] {
            green += 1
        }
        return green
    }

    func testPressedStateFlipsPixelsAndRestores() throws {
        let (label, range) = makeLabel()
        label.layer.setNeedsDisplay()
        let normal = try XCTUnwrap(displayedContents(label))
        XCTAssertEqual(greenCount(normal), 0)

        let layout = try XCTUnwrap(label.textLayout)
        let hit = try XCTUnwrap(
            layout.highlight(at: CGPoint(x: layout.rect(for: range).midX, y: layout.rect(for: range).midY))
        )
        label.trackedHighlight = hit
        label.showPressedState(for: hit)
        let pressed = try XCTUnwrap(displayedContents(label))
        XCTAssertGreaterThan(greenCount(pressed), 20, "pressed state must render the pressed color")

        label.cancelHighlightTracking()
        let restored = try XCTUnwrap(displayedContents(label))
        XCTAssertEqual(greenCount(restored), 0, "cancel must restore the normal rendering")
    }

    func testPressedRoundedBackgroundRendersAndRestores() throws {
        // The user-facing behavior: pressing a highlight shows a rounded
        // capsule behind the range, drawn by the layout (CoreText never
        // draws .backgroundColor).
        let size = CGSize(width: 240, height: 40)
        let range = NSRange(location: 4, length: 4)
        let text = NSMutableAttributedString(string: "tap LINK here", attributes: [
            .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black,
        ])
        text.loom_setHighlight(range, pressedAttributes: [
            .loomTextBackground: LoomTextBackground(
                fillColor: UIColor.green.cgColor, cornerRadius: 4
            ),
        ])
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: size, text: text)

        label.layer.setNeedsDisplay()
        XCTAssertEqual(greenCount(try XCTUnwrap(displayedContents(label))), 0)

        let layout = try XCTUnwrap(label.textLayout)
        let mid = layout.rect(for: range)
        let hit = try XCTUnwrap(layout.highlight(at: CGPoint(x: mid.midX, y: mid.midY)))
        label.trackedHighlight = hit
        label.showPressedState(for: hit)
        XCTAssertGreaterThan(
            greenCount(try XCTUnwrap(displayedContents(label))), 50,
            "pressed capsule must render"
        )

        label.cancelHighlightTracking()
        XCTAssertEqual(greenCount(try XCTUnwrap(displayedContents(label))), 0)
    }

    func testPressedStateRestoresAsyncFlag() throws {
        let (label, range) = makeLabel()
        label.displaysAsynchronously = true
        let layout = try XCTUnwrap(label.textLayout)
        let mid = layout.rect(for: range)
        let hit = try XCTUnwrap(layout.highlight(at: CGPoint(x: mid.midX, y: mid.midY)))
        label.trackedHighlight = hit
        label.showPressedState(for: hit)
        XCTAssertFalse(label.displaysAsynchronously, "pressed rendering is synchronous")
        label.cancelHighlightTracking()
        XCTAssertTrue(label.displaysAsynchronously, "async flag must be restored")
    }
}
#endif
