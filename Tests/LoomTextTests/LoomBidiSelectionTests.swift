//
//  LoomBidiSelectionTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Task 22 — glyph-accurate selection rects for bidirectional text.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomBidiSelectionTests: XCTestCase {

    private func attr(_ string: String, size: CGFloat = 16) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    private func layout(_ string: String, width: CGFloat = 10_000) -> LoomTextLayout {
        LoomTextLayout(containerSize: CGSize(width: width, height: 200), text: attr(string))!
    }

    // MARK: - LTR regression

    func testPlainLTRStaysOneRectPerLine() {
        let l = layout("hello world entirely LTR")
        let rects = l.selectionRects(for: NSRange(location: 3, length: 12))
        XCTAssertEqual(rects.count, 1, "an LTR line must merge back into one rect")
    }

    func testLTRRectMatchesCaretOffsets() {
        // The glyph-based extent must agree with the caret offsets on a
        // purely LTR line (the old implementation's geometry).
        let l = layout("abcdefg hij")
        let range = NSRange(location: 2, length: 6)
        let rects = l.selectionRects(for: range)
        XCTAssertEqual(rects.count, 1)
        let line = l.lines[0]
        let x1 = CTLineGetOffsetForStringIndex(line.ctLine, 2, nil) + line.position.x
        let x2 = CTLineGetOffsetForStringIndex(line.ctLine, 8, nil) + line.position.x
        XCTAssertEqual(rects[0].minX, min(x1, x2), accuracy: 0.75)
        XCTAssertEqual(rects[0].maxX, max(x1, x2), accuracy: 0.75)
    }

    // MARK: - Bidi

    /// "AB " + Hebrew word + " CD": selecting from inside the Latin
    /// prefix into the Hebrew must produce discontiguous segments whose
    /// total width is strictly less than the old min/max-X envelope.
    func testMixedDirectionRangeSplitsIntoSegments() {
        let string = "AB \u{05E9}\u{05DC}\u{05D5}\u{05DD} CD"
        let l = layout(string)
        // Range: "B " + first two Hebrew letters (logical order).
        let range = NSRange(location: 1, length: 4)
        let rects = l.selectionRects(for: range)
        XCTAssertGreaterThanOrEqual(rects.count, 2, "bidi crossing must split; got \(rects)")

        // Envelope comparison: sum of segment widths < envelope width.
        let minX = rects.map(\.minX).min()!
        let maxX = rects.map(\.maxX).max()!
        let total = rects.map(\.width).reduce(0, +)
        XCTAssertLessThan(total, maxX - minX - 0.5,
                          "segments must not cover the unselected middle")
    }

    func testPureRTLRangeIsSingleRect() {
        // One Hebrew word: any sub-range stays a single (RTL) segment.
        let l = layout("\u{05E9}\u{05DC}\u{05D5}\u{05DD}")
        let rects = l.selectionRects(for: NSRange(location: 1, length: 2))
        XCTAssertEqual(rects.count, 1)
        XCTAssertGreaterThan(rects[0].width, 0)
    }

    func testRTLSegmentsSitWhereGlyphsAre() {
        // In "AB שלום CD", the Hebrew glyphs render between the Latin
        // chunks; a Hebrew-only range must produce a rect strictly
        // inside the line, not spanning to either end.
        let string = "AB \u{05E9}\u{05DC}\u{05D5}\u{05DD} CD"
        let l = layout(string)
        let hebrewRange = NSRange(location: 3, length: 4)
        let rects = l.selectionRects(for: hebrewRange)
        let line = l.lines[0]
        let lineStart = line.position.x
        let lineInkEnd = line.position.x + line.lineWidth - line.trailingWhitespaceWidth
        for rect in rects {
            XCTAssertGreaterThan(rect.minX, lineStart + 5)
            XCTAssertLessThan(rect.maxX, lineInkEnd - 5)
        }
    }

    func testFullRangeCoversWholeInkWidth() {
        let string = "AB \u{05E9}\u{05DC}\u{05D5}\u{05DD} CD"
        let l = layout(string)
        let all = NSRange(location: 0, length: (string as NSString).length)
        let rects = l.selectionRects(for: all)
        let line = l.lines[0]
        let minX = rects.map(\.minX).min()!
        let maxX = rects.map(\.maxX).max()!
        XCTAssertEqual(minX, line.position.x, accuracy: 1)
        XCTAssertEqual(
            maxX, line.position.x + line.lineWidth - line.trailingWhitespaceWidth, accuracy: 1.5
        )
    }

    func testMultilineBidiKeepsPerLineOrdering() {
        let string = "AB \u{05E9}\u{05DC}\u{05D5}\u{05DD} CD wrap over to a second line"
        let l = layout(string, width: 150)
        XCTAssertGreaterThan(l.lines.count, 1)
        let all = NSRange(location: 0, length: (string as NSString).length)
        let rects = l.selectionRects(for: all)
        // Rects arrive in line order: minY is non-decreasing.
        let ys = rects.map(\.minY)
        XCTAssertEqual(ys, ys.sorted())
    }
}
