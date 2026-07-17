//
//  LoomSelectionGeometryTests.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Task 15 — selection geometry primitives: locale-aware word ranges,
//  grapheme-cluster snapping, and selectable-range clamping (visible
//  text only; the tail behind an .end truncation token is off-limits).
//

import CoreText
import XCTest
@testable import LoomText

final class LoomSelectionGeometryTests: XCTestCase {

    // MARK: - Helpers

    /// CTFont-based attributes keep the tests platform-independent
    /// (the macOS CI job has no UIKit).
    private func attr(_ string: String, size: CGFloat = 16) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    private func layout(
        _ string: String, width: CGFloat = 10_000, maxRows: Int = 0,
        token: NSAttributedString? = nil
    ) -> LoomTextLayout {
        let container = LoomTextContainer(
            size: CGSize(width: width, height: 10_000),
            maximumNumberOfRows: maxRows,
            truncationToken: token
        )
        return LoomTextLayout(container: container, text: attr(string))!
    }

    /// "a" + family emoji (11 UTF-16 units: 4 surrogate pairs + 3 ZWJ) + "b"
    private let familyString = "a👨‍👩‍👧‍👦b"
    private let familyClusterRange = NSRange(location: 1, length: 11)

    // MARK: - Grapheme clusters

    func testGraphemeClusterAtASCII() {
        let l = layout("abc")
        XCTAssertEqual(l.graphemeClusterRange(at: 1), NSRange(location: 1, length: 1))
    }

    func testGraphemeClusterInsideZWJEmoji() {
        let l = layout(familyString)
        // Any index inside the emoji resolves to the full sequence.
        for index in 1...11 {
            XCTAssertEqual(
                l.graphemeClusterRange(at: index), familyClusterRange,
                "index \(index) should resolve to the whole ZWJ sequence"
            )
        }
        XCTAssertEqual(l.graphemeClusterRange(at: 0), NSRange(location: 0, length: 1))
        XCTAssertEqual(l.graphemeClusterRange(at: 12), NSRange(location: 12, length: 1))
    }

    func testGraphemeClusterCombiningMark() {
        // "e" + U+0301 combining acute = one cluster of two units.
        let l = layout("cafe\u{0301} time")
        XCTAssertEqual(l.graphemeClusterRange(at: 3), NSRange(location: 3, length: 2))
        XCTAssertEqual(l.graphemeClusterRange(at: 4), NSRange(location: 3, length: 2))
    }

    func testGraphemeClusterOutOfBounds() {
        let l = layout("abc")
        XCTAssertNil(l.graphemeClusterRange(at: -1))
        XCTAssertNil(l.graphemeClusterRange(at: 3))
        XCTAssertNil(layout("").graphemeClusterRange(at: 0))
    }

    // MARK: - Word ranges

    func testWordRangeLatin() {
        let l = layout("The quick brown fox")
        XCTAssertEqual(l.wordRange(at: 5), NSRange(location: 4, length: 5)) // "quick"
        XCTAssertEqual(l.wordRange(at: 0), NSRange(location: 0, length: 3)) // "The"
        XCTAssertEqual(l.wordRange(at: 18), NSRange(location: 16, length: 3)) // "fox"
    }

    func testWordRangeAtWhitespaceFallsBackToCluster() {
        let l = layout("The quick brown fox")
        // Index 3 is the space — no word token; fallback is the cluster.
        XCTAssertEqual(l.wordRange(at: 3), NSRange(location: 3, length: 1))
    }

    func testWordRangeCJKSegmentsWords() {
        let l = layout("今天天气真好")
        // Locale-aware segmentation: 今天 / 天气 / 真好 — index 2 must
        // yield the two-character word, never a single character.
        let range = l.wordRange(at: 2)
        XCTAssertEqual(range, NSRange(location: 2, length: 2), "expected 天气, got \(String(describing: range))")
        XCTAssertEqual(l.wordRange(at: 0), NSRange(location: 0, length: 2)) // 今天
    }

    func testWordRangeMixedLatinCJK() throws {
        let l = layout("用 Telegram 聊天")
        let range = try XCTUnwrap(l.wordRange(at: 5)) // inside "Telegram"
        XCTAssertEqual(range, NSRange(location: 2, length: 8))
    }

    func testWordRangeRTLHebrew() throws {
        let l = layout("שלום עולם")
        let range = try XCTUnwrap(l.wordRange(at: 1))
        XCTAssertEqual(range, NSRange(location: 0, length: 4)) // שלום
    }

    func testWordRangeOnZWJEmoji() {
        // UAX #29 treats the emoji as its own segment; via token or the
        // cluster fallback the result must be the full sequence.
        let l = layout(familyString)
        XCTAssertEqual(l.wordRange(at: 6), familyClusterRange)
    }

    func testWordRangeCombiningMarkStaysInWord() {
        let l = layout("cafe\u{0301} time")
        XCTAssertEqual(l.wordRange(at: 2), NSRange(location: 0, length: 5)) // café incl. mark
    }

    func testWordRangeClampsOutOfBoundsIndex() {
        let l = layout("Hi")
        XCTAssertEqual(l.wordRange(at: 99), NSRange(location: 0, length: 2))
        XCTAssertEqual(l.wordRange(at: -5), NSRange(location: 0, length: 2))
    }

    func testWordRangeEmptyText() {
        XCTAssertNil(layout("").wordRange(at: 0))
    }

    func testWordRangeSingleCharacter() {
        XCTAssertEqual(layout("A").wordRange(at: 0), NSRange(location: 0, length: 1))
    }

    // MARK: - Normalized selection ranges

    func testNormalizeExpandsAcrossZWJEmoji() {
        let l = layout(familyString)
        // End lands mid-emoji → expand to the cluster end.
        XCTAssertEqual(
            l.normalizedSelectionRange(for: NSRange(location: 0, length: 3)),
            NSRange(location: 0, length: 12)
        )
        // Start lands mid-emoji → expand back to the cluster start.
        XCTAssertEqual(
            l.normalizedSelectionRange(for: NSRange(location: 6, length: 7)),
            NSRange(location: 1, length: 12)
        )
    }

    func testNormalizeZeroLengthIsNil() {
        let l = layout("hello")
        XCTAssertNil(l.normalizedSelectionRange(for: NSRange(location: 2, length: 0)))
    }

    func testNormalizeDisjointRangeIsNil() {
        let l = layout("hello")
        XCTAssertNil(l.normalizedSelectionRange(for: NSRange(location: 50, length: 5)))
        XCTAssertNil(l.normalizedSelectionRange(for: NSRange(location: NSNotFound, length: 1)))
    }

    func testNormalizePassthroughForPlainRange() {
        let l = layout("hello world")
        XCTAssertEqual(
            l.normalizedSelectionRange(for: NSRange(location: 6, length: 5)),
            NSRange(location: 6, length: 5)
        )
    }

    func testNormalizeClipsToText() {
        let l = layout("hello")
        XCTAssertEqual(
            l.normalizedSelectionRange(for: NSRange(location: 3, length: 99)),
            NSRange(location: 3, length: 2)
        )
    }

    // MARK: - plainText (copy pipeline)

    func testPlainTextSubstring() {
        let l = layout("hello world")
        XCTAssertEqual(l.plainText(in: NSRange(location: 6, length: 5)), "world")
    }

    func testPlainTextStripsAttachmentPlaceholder() {
        let text = NSMutableAttributedString(attributedString: attr("pre "))
        text.append(.loom_attachmentString(
            content: NSNull(), contentSize: CGSize(width: 10, height: 10),
            fontAscent: 12, fontDescent: 4
        ))
        text.append(attr(" post"))
        let l = LoomTextLayout(containerSize: CGSize(width: 10_000, height: 10_000), text: text)!
        let full = NSRange(location: 0, length: text.length)
        XCTAssertEqual(l.plainText(in: full), "pre  post")
    }

    func testPlainTextUsesAltText() {
        let text = NSMutableAttributedString(attributedString: attr("看这个 "))
        text.append(.loom_attachmentString(
            content: NSNull(), contentSize: CGSize(width: 24, height: 24),
            fontAscent: 12, fontDescent: 4, altText: "[地球]"
        ))
        text.append(attr(" 转起来了"))
        let l = LoomTextLayout(containerSize: CGSize(width: 10_000, height: 10_000), text: text)!
        let full = NSRange(location: 0, length: text.length)
        XCTAssertEqual(l.plainText(in: full), "看这个 [地球] 转起来了")
        // A range ending before the attachment copies without it.
        XCTAssertEqual(l.plainText(in: NSRange(location: 0, length: 3)), "看这个")
    }

    func testPlainTextClampsAndEmpty() {
        let l = layout("abc")
        XCTAssertEqual(l.plainText(in: NSRange(location: 1, length: 99)), "bc")
        XCTAssertEqual(l.plainText(in: NSRange(location: 50, length: 5)), "")
        XCTAssertEqual(l.plainText(in: NSRange(location: 0, length: 0)), "")
    }

    func testPlainTextKeepsEmojiIntact() {
        let l = layout(familyString)
        XCTAssertEqual(l.plainText(in: NSRange(location: 0, length: 13)), familyString)
    }

    // MARK: - selectableRange & truncation

    func testSelectableRangeEqualsVisibleWithoutTruncation() {
        let l = layout("short text")
        XCTAssertFalse(l.isTruncated)
        XCTAssertEqual(l.selectableRange, l.visibleRange)
    }

    func testSelectableRangeKeepsWholeLineWhenTokenFits() {
        // A word-wrapped Latin line leaves slack after the break, the
        // ellipsis fits without chopping glyphs — nothing is hidden and
        // the whole visible range stays selectable.
        let text = "Hello world this is a very long sentence for truncation testing"
        let l = layout(text, width: 160, maxRows: 1)
        XCTAssertTrue(l.isTruncated)
        XCTAssertNotNil(l.truncatedLine)
        XCTAssertEqual(l.selectableRange, l.visibleRange)
    }

    /// CJK fills the line edge-to-edge (no word breaks), so appending
    /// the token forces CTLineCreateTruncatedLine to chop glyphs — the
    /// hidden-tail case.
    private let cjkLongText = String(repeating: "很长的中文内容测试文本。", count: 10)

    func testSelectableRangeExcludesTokenHiddenTail() throws {
        let l = layout(cjkLongText, width: 160, maxRows: 1)
        XCTAssertTrue(l.isTruncated)
        XCTAssertNotNil(l.truncatedLine)
        let tokenRect = try XCTUnwrap(l.truncationTokenRect)

        // visibleRange keeps the full last-line range (YYText parity);
        // selection must stop where the token starts.
        XCTAssertLessThan(l.selectableRange.length, l.visibleRange.length)
        XCTAssertGreaterThan(l.selectableRange.length, 0)

        // The selectable tail must sit at or left of the token's origin.
        let lastVisible = l.selectableRange.location + l.selectableRange.length
        let rects = l.selectionRects(for: NSRange(location: lastVisible - 1, length: 1))
        let tailRect = try XCTUnwrap(rects.last)
        XCTAssertLessThanOrEqual(tailRect.maxX, tokenRect.minX + 1.0)
    }

    func testNormalizeClampsIntoSelectableRange() {
        let l = layout(cjkLongText, width: 160, maxRows: 1)
        let full = NSRange(location: 0, length: (cjkLongText as NSString).length)
        XCTAssertEqual(l.normalizedSelectionRange(for: full), l.selectableRange)
    }

    func testWordRangeInHiddenTailClampsBack() throws {
        let l = layout(cjkLongText, width: 160, maxRows: 1)
        // An index deep in the hidden tail clamps to the last selectable
        // character's word.
        let range = try XCTUnwrap(l.wordRange(at: (cjkLongText as NSString).length - 1))
        let upper = l.selectableRange.location + l.selectableRange.length
        XCTAssertLessThanOrEqual(range.location + range.length, upper)
        XCTAssertGreaterThan(range.length, 0)
    }

    func testSelectableRangeWithCustomToken() throws {
        let token = NSMutableAttributedString(attributedString: attr("…全文", size: 16))
        let text = String(repeating: "折叠内容测试文本。", count: 12)
        let l = layout(text, width: 200, maxRows: 2, token: token)
        XCTAssertTrue(l.isTruncated)
        let tokenRect = try XCTUnwrap(l.truncationTokenRect)
        XCTAssertLessThan(l.selectableRange.length, l.visibleRange.length)
        let lastVisible = l.selectableRange.location + l.selectableRange.length
        let rects = l.selectionRects(for: NSRange(location: lastVisible - 1, length: 1))
        let tailRect = try XCTUnwrap(rects.last)
        XCTAssertLessThanOrEqual(tailRect.maxX, tokenRect.minX + 1.0)
    }
}
