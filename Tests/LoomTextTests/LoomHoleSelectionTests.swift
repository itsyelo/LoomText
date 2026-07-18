//
//  LoomHoleSelectionTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Task 23 — hole-aware selection: the span hidden behind a .start or
//  .middle truncation token contributes no geometry and never copies.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomHoleSelectionTests: XCTestCase {

    private func attr(_ string: String) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    private let pathText = "/Users/yelo/Projects/LoomText/Sources/LoomText/LoomTextLayout.swift"

    private func truncated(_ type: LoomTextTruncationType, width: CGFloat = 220) -> LoomTextLayout {
        let container = LoomTextContainer(
            size: CGSize(width: width, height: 10_000),
            maximumNumberOfRows: 1,
            truncationType: type
        )
        return LoomTextLayout(container: container, text: attr(pathText))!
    }

    // MARK: - Span computation

    func testMiddleProducesTwoSpansAroundTheHole() {
        let l = truncated(.middle)
        XCTAssertTrue(l.isTruncated)
        XCTAssertEqual(l.selectableRanges.count, 2, "\(l.selectableRanges)")
        let head = l.selectableRanges[0]
        let tail = l.selectableRanges[1]
        XCTAssertEqual(head.location, 0)
        XCTAssertGreaterThan(tail.location, head.location + head.length, "a hole must separate the spans")
        XCTAssertEqual(
            tail.location + tail.length, (pathText as NSString).length,
            "the tail must reach the end of the whole text"
        )
    }

    func testStartProducesTailSpanBeyondVisibleRange() {
        let l = truncated(.start)
        XCTAssertTrue(l.isTruncated)
        XCTAssertEqual(l.selectableRanges.count, 1)
        let span = l.selectableRanges[0]
        // .start shows the *end* of the text.
        XCTAssertEqual(span.location + span.length, (pathText as NSString).length)
        XCTAssertGreaterThan(span.location, 0)
    }

    func testEndKeepsSingleSpanRegression() {
        let l = truncated(.end)
        XCTAssertEqual(l.selectableRanges, [l.selectableRange])
    }

    func testUntruncatedKeepsSingleSpan() {
        let l = LoomTextLayout(
            containerSize: CGSize(width: 10_000, height: 100), text: attr("plain text")
        )!
        XCTAssertEqual(l.selectableRanges, [l.selectableRange])
        XCTAssertEqual(l.selectableRange, l.visibleRange)
    }

    // MARK: - Copy excludes the hole

    func testCopyOverTheHoleJoinsHeadAndTail() {
        let l = truncated(.middle)
        let envelope = l.selectableRange
        let copied = l.plainText(in: envelope)
        let head = l.selectableRanges[0]
        let tail = l.selectableRanges[1]
        let ns = pathText as NSString
        XCTAssertEqual(
            copied,
            ns.substring(with: head) + ns.substring(with: tail),
            "copy must be the visible head + tail, nothing from the hole"
        )
        XCTAssertLessThan(copied.utf16.count, envelope.length, "the hole must be missing")
    }

    func testPlainTextIsVisibleOnlyForEndTruncation() {
        let l = truncated(.end)
        let full = NSRange(location: 0, length: (pathText as NSString).length)
        // The hidden tail behind the token never copies.
        XCTAssertEqual(l.plainText(in: full).utf16.count, l.selectableRange.length)
    }

    // MARK: - Geometry excludes the hole

    func testNoSelectionRectsIntersectTheToken() throws {
        let l = truncated(.middle)
        let tokenRect = try XCTUnwrap(l.truncationTokenRect).insetBy(dx: 0.5, dy: 0)
        let rects = l.selectionRects(for: l.selectableRange)
        XCTAssertFalse(rects.isEmpty)
        for rect in rects {
            XCTAssertFalse(
                rect.intersects(tokenRect),
                "selection rect \(rect) must not cover the token \(tokenRect)"
            )
        }
    }

    /// The drawn tail (remainder text) must produce highlight geometry
    /// too — rects come from the substituted line's glyphs, so what is
    /// highlighted is exactly what is on screen.
    func testBothSpansProduceGeometry() throws {
        let l = truncated(.middle)
        let tokenRect = try XCTUnwrap(l.truncationTokenRect)
        let rects = l.selectionRects(for: l.selectableRange)
        XCTAssertTrue(
            rects.contains { $0.maxX <= tokenRect.minX + 0.5 },
            "head span must highlight: \(rects)"
        )
        XCTAssertTrue(
            rects.contains { $0.minX >= tokenRect.maxX - 0.5 },
            "tail span must highlight: \(rects)"
        )
    }

    // MARK: - Normalization snaps out of the hole

    func testEndpointInsideHoleSnapsOutward() {
        let l = truncated(.middle)
        let head = l.selectableRanges[0]
        let tail = l.selectableRanges[1]
        let holeMid = (head.location + head.length + tail.location) / 2

        // Start in the hole → snaps forward to the tail span.
        let fromHole = l.normalizedSelectionRange(
            for: NSRange(location: holeMid, length: tail.location + tail.length - holeMid)
        )
        XCTAssertEqual(fromHole?.location, tail.location)

        // End in the hole → snaps back to the head span's end.
        let intoHole = l.normalizedSelectionRange(
            for: NSRange(location: head.location, length: holeMid - head.location)
        )
        XCTAssertEqual(intoHole.map { $0.location + $0.length }, head.location + head.length)
    }

    func testRangeEntirelyInsideHoleIsNil() {
        let l = truncated(.middle)
        let head = l.selectableRanges[0]
        let tail = l.selectableRanges[1]
        let holeStart = head.location + head.length
        let holeLength = tail.location - holeStart
        guard holeLength >= 2 else { return }
        XCTAssertNil(l.normalizedSelectionRange(
            for: NSRange(location: holeStart + 1, length: holeLength - 2)
        ))
    }
}
