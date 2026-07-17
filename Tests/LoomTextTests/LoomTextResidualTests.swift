//
//  LoomTextResidualTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Phase 0 gate: prove "measure = render, zero residual" — ink drawn by
//  the same LoomTextLayout that reported textBoundingSize never escapes
//  the reported box, and a collapsed layout's prefix is byte-identical
//  to the expanded layout.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomTextResidualTests: XCTestCase {

    /// Margin around the claimed box so escaping ink is detectable.
    private let margin: CGFloat = 20

    /// Renders `layout` centered in a padded canvas and asserts all ink
    /// stays inside the claimed `textBoundingSize` box.
    ///
    /// Gate semantics: **vertical containment is strict** (zero
    /// tolerance by default) — the vertical extent is what feeds cell
    /// heights, and vertical residual was the UILabel problem LoomText
    /// exists to kill. Horizontal allows ±1pt by default: glyphs with
    /// negative side bearings (e.g. a line-leading "j") paint slightly
    /// outside their typographic origin. That ink overshoot is inherent
    /// to typography — UILabel and YYText render it identically — and is
    /// not a measurement residual.
    private func assertInkContained(
        _ layout: LoomTextLayout,
        scale: CGFloat,
        toleranceX: CGFloat = 1,
        toleranceY: CGFloat = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        let claimed = layout.textBoundingSize
        let canvas = CGSize(width: claimed.width + margin * 2, height: claimed.height + margin * 2)
        let rendered = try PixelCanvas(
            layout: layout, canvas: canvas, point: CGPoint(x: margin, y: margin), scale: scale
        )
        let ink = try XCTUnwrap(rendered.inkRect, "expected ink", file: file, line: line)
        let claimedBox = CGRect(x: margin, y: margin, width: claimed.width, height: claimed.height)
            .insetBy(dx: -toleranceX, dy: -toleranceY)
        XCTAssertTrue(
            claimedBox.contains(ink),
            "ink \(ink) escapes claimed box \(claimedBox) at scale \(scale)",
            file: file, line: line
        )
        return ink
    }

    // MARK: - Matrix: ink containment

    func testSingleLineLatin1xAnd3x() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: TestText.plain("Hello LoomText jygp"))
        )
        _ = try assertInkContained(layout, scale: 1)
        _ = try assertInkContained(layout, scale: 3)
    }

    func testMultilineLatin3x() throws {
        let text = TestText.plain(
            "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. Yellow jelly."
        )
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: text)
        )
        XCTAssertGreaterThan(layout.rowCount, 3)
        _ = try assertInkContained(layout, scale: 3)
    }

    func testCJKMixed3x() throws {
        let text = TestText.plain("布局引擎渲染中英文混排 LoomText 零残差验证，行高稳定不跳动。", fontName: "PingFang SC")
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 140, height: 10_000), text: text)
        )
        XCTAssertGreaterThan(layout.rowCount, 2)
        _ = try assertInkContained(layout, scale: 3)
    }

    func testEmojiZWJ3x() throws {
        let text = TestText.plain("emoji 👨‍👩‍👧‍👦 in 🧵 line 🎉 wrap", fontName: "Helvetica")
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 100, height: 10_000), text: text)
        )
        // Color emoji bitmaps may bleed slightly past typographic bounds;
        // measure with a small tolerance and record the reality.
        _ = try assertInkContained(layout, scale: 3, toleranceX: 2, toleranceY: 2)
    }

    func testRTLArabic3x() throws {
        let text = TestText.plain("النص العربي يُعرض من اليمين إلى اليسار بدون تجاوز الحدود المقاسة", fontName: "Geeza Pro")
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 160, height: 10_000), text: text)
        )
        XCTAssertGreaterThan(layout.rowCount, 1)
        _ = try assertInkContained(layout, scale: 3)
    }

    func testMaxLinesTruncated3x() throws {
        let text = TestText.plain(
            "Collapsed feed cell body text that continues for quite a while so that two rows overflow."
        )
        let container = LoomTextContainer(size: CGSize(width: 150, height: 10_000), maximumNumberOfRows: 2)
        let layout = try XCTUnwrap(LoomTextLayout(container: container, text: text))
        XCTAssertTrue(layout.isTruncated)
        _ = try assertInkContained(layout, scale: 3)
    }

    func testLineSpacing3x() throws {
        let text = TestText.withLineSpacing(
            "Line spacing adjusted paragraph that wraps across several lines for the residual matrix.",
            spacing: 8
        )
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 150, height: 10_000), text: text)
        )
        XCTAssertGreaterThan(layout.rowCount, 2)
        _ = try assertInkContained(layout, scale: 3)
    }

    // MARK: - Collapsed prefix == expanded prefix (byte identical)

    func testCollapsedRenderingIsExpandedPrefix() throws {
        let text = TestText.plain(
            "Expandable feed post body. Tap more to expand. The collapsed two lines must match the expanded layout exactly, byte for byte, at 3x."
        )
        let size = CGSize(width: 150, height: 10_000)
        let scale: CGFloat = 3

        let full = try XCTUnwrap(LoomTextLayout(containerSize: size, text: text))
        let container = LoomTextContainer(size: size, maximumNumberOfRows: 2)
        let collapsed = try XCTUnwrap(LoomTextLayout(container: container, text: text))
        XCTAssertGreaterThan(full.rowCount, collapsed.rowCount)

        // Same canvas, same origin: the collapsed band must be identical.
        let canvas = CGSize(width: size.width, height: full.textBoundingSize.height + 10)
        let fullCanvas = try PixelCanvas(layout: full, canvas: canvas, point: .zero, scale: scale)
        let collapsedCanvas = try PixelCanvas(layout: collapsed, canvas: canvas, point: .zero, scale: scale)

        // The truncated (last) row renders a token, so byte equality
        // holds for every row above it; the truncated row itself must
        // still stay within the same vertical band.
        let prefixBottom = collapsed.lines[collapsed.lines.count - 2].bounds.maxY
        XCTAssertEqual(
            fullCanvas.rowBand(fromY: 0, toY: prefixBottom),
            collapsedCanvas.rowBand(fromY: 0, toY: prefixBottom),
            "collapsed prefix diverges from expanded rendering"
        )
        // And the collapsed canvas has no ink below its last line.
        let bandBottom = collapsed.lines[collapsed.lines.count - 1].bounds.maxY
        let below = collapsedCanvas.rowBand(fromY: ceil(bandBottom) + 1, toY: canvas.height)
        XCTAssertFalse(
            below.enumerated().contains { offset, byte in (offset % 4 == 3) && byte > PixelCanvas.inkAlphaThreshold },
            "collapsed layout leaked ink below its last row"
        )
        // Token-free collapse (truncationType .none) is byte-identical
        // across ALL collapsed rows — the original Phase 0 guarantee.
        let plainContainer = LoomTextContainer(
            size: size, maximumNumberOfRows: 2, truncationType: .none
        )
        let plain = try XCTUnwrap(LoomTextLayout(container: plainContainer, text: text))
        let plainCanvas = try PixelCanvas(layout: plain, canvas: canvas, point: .zero, scale: scale)
        XCTAssertEqual(
            fullCanvas.rowBand(fromY: 0, toY: bandBottom),
            plainCanvas.rowBand(fromY: 0, toY: bandBottom)
        )
    }
}
