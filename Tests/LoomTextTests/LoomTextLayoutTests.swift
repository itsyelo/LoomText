//
//  LoomTextLayoutTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreText
import XCTest
@testable import LoomText

final class LoomTextLayoutTests: XCTestCase {

    // MARK: - Helpers

    /// CTFont-based attributes keep the tests platform-independent
    /// (the macOS CI job has no UIKit).
    private func attr(_ string: String, fontName: String = "Helvetica", size: CGFloat = 16) -> NSAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    private let longText = "The quick brown fox jumps over the lazy dog. "
        + "Pack my box with five dozen liquor jugs. "
        + "How vexingly quick daft zebras jump!"

    // MARK: - Construction

    func testInvalidContainerSizeFails() {
        XCTAssertNil(LoomTextLayout(containerSize: .zero, text: attr("hi")))
        XCTAssertNil(LoomTextLayout(containerSize: CGSize(width: -10, height: 100), text: attr("hi")))
    }

    func testEmptyText() throws {
        let layout = try XCTUnwrap(LoomTextLayout(containerSize: CGSize(width: 100, height: 100), text: attr("")))
        XCTAssertTrue(layout.lines.isEmpty)
        XCTAssertEqual(layout.rowCount, 0)
        XCTAssertEqual(layout.textBoundingSize, .zero)
        XCTAssertEqual(layout.visibleRange, NSRange(location: 0, length: 0))
        XCTAssertFalse(layout.isTruncated)
    }

    func testEmptyTextWithInsetsMeasuresZero() throws {
        // Deliberate divergence from YYText: empty content must not
        // reserve the insets envelope (YYText returns (right, bottom)).
        let container = LoomTextContainer(
            size: CGSize(width: 100, height: 100),
            insets: LoomEdgeInsets(top: 10, left: 5, bottom: 7, right: 3)
        )
        let layout = try XCTUnwrap(LoomTextLayout(container: container, text: attr("")))
        XCTAssertEqual(layout.textBoundingSize, .zero)
    }

    func testContainerTooShortForAnyLine() throws {
        // Height fits zero lines: everything is clipped. Deliberate
        // divergence from YYText (which reports isTruncated=false with a
        // full visibleRange here): nothing visible → truncated, empty range.
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 2), text: attr(longText))
        )
        XCTAssertTrue(layout.lines.isEmpty)
        XCTAssertEqual(layout.rowCount, 0)
        XCTAssertTrue(layout.isTruncated)
        XCTAssertEqual(layout.visibleRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(layout.textBoundingSize, .zero)
    }

    func testDefensiveCopy() throws {
        let mutable = NSMutableAttributedString(attributedString: attr("hello"))
        let layout = try XCTUnwrap(LoomTextLayout(containerSize: CGSize(width: 200, height: 100), text: mutable))
        mutable.mutableString.setString("changed")
        XCTAssertEqual(layout.text.string, "hello")
    }

    // MARK: - Metrics

    func testSingleLineHeightIsAscentPlusDescent() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: attr("Hello World"))
        )
        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.rowCount, 1)
        // YYText semantics: bounding height reaches exactly the line's
        // bottom (first-baseline placement + descent) — no trailing font
        // leading. The framesetter may place the first baseline using the
        // font's ascent, which can exceed the CTLine's typographic ascent
        // (observed: Helvetica 16 → baseline ~16, line ascent ~12.3), so
        // the line's own maxY is the authority, not ascent+descent sums.
        let line = layout.lines[0]
        XCTAssertEqual(layout.textBoundingSize.height, ceil(line.bounds.maxY), accuracy: 0.001)
        XCTAssertEqual(line.bounds.height, line.ascent + line.descent, accuracy: 0.001)
        // Sanity: within one line's plausible envelope, leading excluded.
        XCTAssertLessThan(layout.textBoundingSize.height, (line.ascent + line.descent) * 1.5)
        XCTAssertFalse(layout.isTruncated)
        XCTAssertEqual(layout.visibleRange.length, "Hello World".count)
    }

    func testMultilineWrapsAndIsNotTruncated() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: attr(longText))
        )
        XCTAssertGreaterThan(layout.rowCount, 1)
        XCTAssertEqual(layout.lines.count, layout.rowCount)
        XCTAssertFalse(layout.isTruncated)
        XCTAssertEqual(layout.visibleRange.length, longText.count)
        // Rows are stacked top to bottom.
        for (a, b) in zip(layout.lines, layout.lines.dropFirst()) {
            XCTAssertLessThan(a.position.y, b.position.y)
        }
    }

    func testBoundingSizeIncludesInsets() throws {
        let insets = LoomEdgeInsets(top: 10, left: 5, bottom: 7, right: 3)
        let plain = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: attr("Hello"))
        )
        let container = LoomTextContainer(size: CGSize(width: 400, height: 100), insets: insets)
        let inset = try XCTUnwrap(LoomTextLayout(container: container, text: attr("Hello")))
        XCTAssertEqual(inset.textBoundingSize.height, plain.textBoundingSize.height + 10 + 7, accuracy: 1.0)
        XCTAssertEqual(inset.textBoundingSize.width, plain.textBoundingSize.width + 5 + 3, accuracy: 1.0)
    }

    func testBoundingSizeVersusFramesetterSuggest() throws {
        let text = attr(longText)
        let width: CGFloat = 150
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: width, height: 10_000), text: text)
        )
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: text.length), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        // Line-bounds union excludes trailing leading — never taller than suggest.
        XCTAssertLessThanOrEqual(layout.textBoundingSize.height, ceil(suggested.height))
        // Width: line bounds include trailing whitespace at wrap points
        // (YYText parity), so the union may exceed both the constraint and
        // the suggested width. Net of trailing whitespace they must agree.
        let maxContentRight = layout.lines
            .map { $0.bounds.maxX - $0.trailingWhitespaceWidth }
            .max() ?? 0
        XCTAssertEqual(ceil(maxContentRight), ceil(suggested.width), accuracy: 2.0)
        let maxTrailing = layout.lines.map(\.trailingWhitespaceWidth).max() ?? 0
        XCTAssertLessThanOrEqual(layout.textBoundingSize.width, ceil(suggested.width + maxTrailing))
    }

    // MARK: - Truncation

    func testMaximumNumberOfRows() throws {
        let container = LoomTextContainer(
            size: CGSize(width: 150, height: 10_000), maximumNumberOfRows: 2
        )
        let layout = try XCTUnwrap(LoomTextLayout(container: container, text: attr(longText)))
        XCTAssertEqual(layout.rowCount, 2)
        XCTAssertEqual(layout.lines.count, 2)
        XCTAssertTrue(layout.isTruncated)
        XCTAssertLessThan(layout.visibleRange.length, longText.count)
    }

    func testCollapsedPrefixMatchesExpandedPixelForPixel() throws {
        // Loom feed expand/collapse: the first N lines of the unlimited
        // layout must be identical to the maxLines=N layout.
        let size = CGSize(width: 150, height: 10_000)
        let full = try XCTUnwrap(LoomTextLayout(containerSize: size, text: attr(longText)))
        let container = LoomTextContainer(size: size, maximumNumberOfRows: 2)
        let collapsed = try XCTUnwrap(LoomTextLayout(container: container, text: attr(longText)))
        for (a, b) in zip(collapsed.lines, full.lines.prefix(2)) {
            XCTAssertEqual(a.bounds, b.bounds)
            XCTAssertEqual(a.range, b.range)
            XCTAssertEqual(a.position, b.position)
        }
    }

    func testHeightClippingTruncates() throws {
        let oneLine = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: attr("A"))
        )
        let lineHeight = oneLine.textBoundingSize.height
        // Room for ~2.5 lines: the third must be clipped, not half-drawn.
        let clipped = try XCTUnwrap(
            LoomTextLayout(
                containerSize: CGSize(width: 150, height: lineHeight * 2.5), text: attr(longText)
            )
        )
        XCTAssertEqual(clipped.rowCount, 2)
        XCTAssertTrue(clipped.isTruncated)
        XCTAssertLessThanOrEqual(clipped.textBoundingSize.height, ceil(lineHeight * 2.5))
    }

    // MARK: - Content variety

    func testCJKEmojiMixed() throws {
        let mixed = attr("布局引擎 LoomText 渲染 👨‍👩‍👧‍👦 emoji 和中英文混排 mixed content")
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 120, height: 10_000), text: mixed)
        )
        XCTAssertGreaterThan(layout.rowCount, 1)
        XCTAssertFalse(layout.isTruncated)
        XCTAssertEqual(layout.visibleRange.length, mixed.length)
        XCTAssertGreaterThan(layout.textBoundingSize.width, 0)
    }

    func testRTLArabicConstructs() throws {
        let arabic = attr("النص العربي يُعرض من اليمين إلى اليسار في هذا الاختبار الطويل نسبيا")
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: arabic)
        )
        XCTAssertGreaterThan(layout.rowCount, 1)
        for line in layout.lines {
            XCTAssertLessThanOrEqual(line.bounds.maxX, 150 + 1)
        }
    }

    // MARK: - Hit testing

    func testCharacterIndexMonotonicAlongLine() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: attr("Hello World"))
        )
        let midY = layout.lines[0].bounds.midY
        var last = -1
        for x in stride(from: CGFloat(0), through: layout.textBoundingSize.width, by: 8) {
            let index = try XCTUnwrap(layout.characterIndex(at: CGPoint(x: x, y: midY)))
            XCTAssertGreaterThanOrEqual(index, last)
            last = index
        }
        XCTAssertEqual(layout.characterIndex(at: CGPoint(x: 0, y: midY)), 0)
        XCTAssertEqual(last, "Hello World".count)
    }

    func testLineIndexAtPoint() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: attr(longText))
        )
        let first = layout.lines[0]
        let second = layout.lines[1]
        XCTAssertEqual(layout.lineIndex(at: CGPoint(x: first.bounds.midX, y: first.bounds.midY)), 0)
        XCTAssertEqual(layout.lineIndex(at: CGPoint(x: second.bounds.midX, y: second.bounds.midY)), 1)
        XCTAssertNil(layout.lineIndex(at: CGPoint(x: 10, y: -50)))
        XCTAssertNil(layout.lineIndex(at: CGPoint(x: 10, y: layout.textBoundingSize.height + 500)))
        // Closest never returns nil for a non-empty layout.
        XCTAssertEqual(layout.closestLineIndex(to: CGPoint(x: 10, y: -50)), 0)
        XCTAssertEqual(
            layout.closestLineIndex(to: CGPoint(x: 10, y: layout.textBoundingSize.height + 500)),
            layout.lines.count - 1
        )
    }

    func testEmptyLayoutHitTestReturnsNil() throws {
        let layout = try XCTUnwrap(LoomTextLayout(containerSize: CGSize(width: 100, height: 100), text: attr("")))
        XCTAssertNil(layout.lineIndex(at: .zero))
        XCTAssertNil(layout.closestLineIndex(to: .zero))
        XCTAssertNil(layout.characterIndex(at: .zero))
    }

    // MARK: - Concurrency

    func testConcurrentConstructionMatchesSerial() throws {
        let texts = (0..<64).map { attr("Concurrent layout stress item \($0) — \(longText)") }
        let serial = texts.map {
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: $0)!.textBoundingSize
        }
        let lock = NSLock()
        var concurrent = [Int: CGSize]()
        DispatchQueue.concurrentPerform(iterations: texts.count) { i in
            let layout = LoomTextLayout(
                containerSize: CGSize(width: 150, height: 10_000), text: texts[i]
            )!
            lock.lock()
            concurrent[i] = layout.textBoundingSize
            lock.unlock()
        }
        for i in 0..<texts.count {
            XCTAssertEqual(concurrent[i], serial[i])
        }
    }

    func testLayoutIsUsableAcrossThreads() throws {
        // Build on a background queue, hit-test on another — the pattern
        // Loom's pipeline relies on.
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: attr(longText))
        )
        let expectation = expectation(description: "cross-thread use")
        DispatchQueue.global().async {
            _ = layout.characterIndex(at: CGPoint(x: 20, y: 10))
            _ = layout.textBoundingSize
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
