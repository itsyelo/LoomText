//
//  LoomTruncationTokenTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomTruncationTokenTests: XCTestCase {

    private let longString = "Feed post body that definitely wraps across more than two lines of content here."

    private func font(_ size: CGFloat = 16) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func attr(_ string: String, size: CGFloat = 16) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(size)]
        )
    }

    private func makeToken(_ string: String = "\u{2026}more", highlighted: Bool = false) -> NSAttributedString {
        let token = NSMutableAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font()]
        )
        if highlighted {
            token.loom_setHighlight(
                NSRange(location: 0, length: token.length),
                pressedAttributes: [.loomTestPressedMarker: true],
                userInfo: ["action": "expand"]
            )
        }
        return token
    }

    private func truncatedLayout(
        token: NSAttributedString?,
        type: LoomTextTruncationType = .end
    ) throws -> LoomTextLayout {
        let container = LoomTextContainer(
            size: CGSize(width: 150, height: 10_000),
            maximumNumberOfRows: 2,
            truncationType: type,
            truncationToken: token
        )
        return try XCTUnwrap(LoomTextLayout(container: container, text: attr(longString)))
    }

    // MARK: - Construction

    func testCustomTokenBuildsTruncatedLine() throws {
        let layout = try truncatedLayout(token: makeToken())
        XCTAssertTrue(layout.isTruncated)
        let truncated = try XCTUnwrap(layout.truncatedLine)
        XCTAssertEqual(truncated.index, layout.lines.count - 1)
        XCTAssertEqual(layout.resolvedTruncationToken?.string, "\u{2026}more")
        let tokenRect = try XCTUnwrap(layout.truncationTokenRect)
        XCTAssertGreaterThan(tokenRect.width, 0)
        // Token sits at the trailing edge of the truncated line, within
        // the container width.
        XCTAssertLessThanOrEqual(tokenRect.maxX, 150 + 1)
        XCTAssertEqual(tokenRect.midY, truncated.bounds.midY, accuracy: truncated.bounds.height)
    }

    func testDefaultEllipsisWhenNoToken() throws {
        let layout = try truncatedLayout(token: nil)
        XCTAssertNotNil(layout.truncatedLine)
        XCTAssertEqual(layout.resolvedTruncationToken?.string, "\u{2026}")
        XCTAssertNotNil(layout.truncationTokenRect)
    }

    func testNoTruncatedLineWhenNotTruncated() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(
                container: LoomTextContainer(
                    size: CGSize(width: 400, height: 100), truncationToken: makeToken()
                ),
                text: attr("short")
            )
        )
        XCTAssertFalse(layout.isTruncated)
        XCTAssertNil(layout.truncatedLine)
        XCTAssertNil(layout.truncationTokenRect)
        XCTAssertNil(layout.resolvedTruncationToken)
    }

    func testTruncationTypeNoneSkipsToken() throws {
        let layout = try truncatedLayout(token: makeToken(), type: .none)
        XCTAssertTrue(layout.isTruncated)
        XCTAssertNil(layout.truncatedLine)
        XCTAssertNil(layout.truncationTokenRect)
    }

    // MARK: - .start / .middle (Task 21)

    func testStartTruncationPlacesTokenAtLineStart() throws {
        let layout = try truncatedLayout(token: makeToken(), type: .start)
        XCTAssertTrue(layout.isTruncated)
        XCTAssertNotNil(layout.truncatedLine)
        let rect = try XCTUnwrap(layout.truncationTokenRect)
        let line = try XCTUnwrap(layout.truncatedLine)
        XCTAssertGreaterThan(rect.width, 0)
        // The token leads the line: its left edge sits at the line's
        // drawing origin, well before the horizontal middle.
        XCTAssertEqual(rect.minX, line.position.x, accuracy: 2)
        XCTAssertLessThan(rect.maxX, 75)
    }

    func testMiddleTruncationPlacesTokenInsideTheLine() throws {
        let layout = try truncatedLayout(token: makeToken(), type: .middle)
        XCTAssertTrue(layout.isTruncated)
        let rect = try XCTUnwrap(layout.truncationTokenRect)
        let line = try XCTUnwrap(layout.truncatedLine)
        XCTAssertGreaterThan(rect.width, 0)
        // Strictly interior: text on both sides of the token.
        XCTAssertGreaterThan(rect.minX, line.position.x + 5)
        XCTAssertLessThan(rect.maxX, line.position.x + line.lineWidth - 5)
    }

    func testTokenHighlightHitTestsForStartAndMiddle() throws {
        for type in [LoomTextTruncationType.start, .middle] {
            let layout = try truncatedLayout(token: makeToken(highlighted: true), type: type)
            let rect = try XCTUnwrap(layout.truncationTokenRect, "\(type)")
            let hit = layout.truncationTokenHighlight(
                at: CGPoint(x: rect.midX, y: rect.midY)
            )
            XCTAssertNotNil(hit, "token tap must hit for \(type)")
            // Just outside the rect: no hit.
            XCTAssertNil(layout.truncationTokenHighlight(
                at: CGPoint(x: rect.maxX + 10, y: rect.midY)
            ), "miss must stay a miss for \(type)")
        }
    }

    func testStartAndMiddleExposeVisibleSpans() throws {
        for type in [LoomTextTruncationType.start, .middle] {
            let layout = try truncatedLayout(token: makeToken(), type: type)
            // Hole-aware (Task 23): spans cover the drawn text; the
            // envelope spans first…last.
            XCTAssertFalse(layout.selectableRanges.isEmpty, "\(type)")
            let first = layout.selectableRanges.first!
            let last = layout.selectableRanges.last!
            XCTAssertEqual(layout.selectableRange.location, first.location, "\(type)")
            XCTAssertEqual(
                layout.selectableRange.location + layout.selectableRange.length,
                last.location + last.length, "\(type)"
            )
        }
    }

    func testOversizedTokenDoesNotCrash() throws {
        let huge = makeToken(String(repeating: "wide token ", count: 20))
        let layout = try truncatedLayout(token: huge)
        // CTLineCreateTruncatedLine may fail or degrade; the layout must
        // stay consistent either way.
        XCTAssertTrue(layout.isTruncated)
        if let rect = layout.truncationTokenRect {
            XCTAssertGreaterThan(rect.width, 0)
        }
    }

    // MARK: - Rendering

    func testTokenRendersInkInTokenRect() throws {
        let layout = try truncatedLayout(token: makeToken())
        let tokenRect = try XCTUnwrap(layout.truncationTokenRect)
        let canvas = CGSize(
            width: layout.textBoundingSize.width + 10,
            height: layout.textBoundingSize.height + 10
        )
        let withToken = try PixelCanvas(layout: layout, canvas: canvas, point: .zero, scale: 3)

        let plain = try truncatedLayout(token: makeToken(), type: .none)
        let withoutToken = try PixelCanvas(layout: plain, canvas: canvas, point: .zero, scale: 3)

        // The token band must contain ink that the token-free layout lacks.
        XCTAssertNotEqual(
            withToken.rowBand(fromY: tokenRect.minY, toY: tokenRect.maxY),
            withoutToken.rowBand(fromY: tokenRect.minY, toY: tokenRect.maxY)
        )
        XCTAssertGreaterThan(withToken.inkCount, withoutToken.inkCount)
    }

    func testTruncatedLayoutInkStaysContained() throws {
        let layout = try truncatedLayout(token: makeToken())
        let claimed = layout.textBoundingSize
        let margin: CGFloat = 20
        let rendered = try PixelCanvas(
            layout: layout,
            canvas: CGSize(width: claimed.width + margin * 2, height: claimed.height + margin * 2),
            point: CGPoint(x: margin, y: margin),
            scale: 3
        )
        let ink = try XCTUnwrap(rendered.inkRect)
        let box = CGRect(x: margin, y: margin, width: claimed.width, height: claimed.height)
            .insetBy(dx: -1, dy: 0)
        XCTAssertTrue(box.contains(ink), "token ink \(ink) escapes \(box)")
    }

    // MARK: - Token hit-testing

    func testTokenHighlightHitAndInlineExclusion() throws {
        let layout = try truncatedLayout(token: makeToken(highlighted: true))
        let tokenRect = try XCTUnwrap(layout.truncationTokenRect)
        let probe = CGPoint(x: tokenRect.midX, y: tokenRect.midY)

        let hit = try XCTUnwrap(layout.truncationTokenHighlight(at: probe))
        XCTAssertEqual(hit.highlight.userInfo?["action"] as? String, "expand")
        XCTAssertEqual(hit.range, NSRange(location: 0, length: layout.resolvedTruncationToken!.length))

        // The same point must not resolve to an inline highlight.
        XCTAssertNil(layout.highlight(at: probe))
        // A point on line 1 must not hit the token.
        let firstLine = layout.lines[0]
        XCTAssertNil(
            layout.truncationTokenHighlight(
                at: CGPoint(x: firstLine.bounds.midX, y: firstLine.bounds.midY)
            )
        )
    }
}
