//
//  LoomTextDecorationTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Task 19 — self-drawn underline/strikethrough (CTLineDraw ignores
//  both) and LoomTextBackground strokes, verified per pixel.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomTextDecorationTests: XCTestCase {

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    private func text(
        _ string: String,
        size: CGFloat = 16,
        attributes extra: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        attributes.merge(extra) { _, new in new }
        return NSAttributedString(string: string, attributes: attributes)
    }

    private func layout(_ text: NSAttributedString, width: CGFloat = 400) -> LoomTextLayout {
        LoomTextLayout(containerSize: CGSize(width: width, height: 200), text: text)!
    }

    private func redInk(_ canvas: PixelCanvas, fromY: CGFloat, toY: CGFloat) -> Int {
        var count = 0
        let band = canvas.rowBand(fromY: fromY, toY: toY)
        var index = band.startIndex
        while index < band.endIndex {
            let alpha = band[index + 3]
            if alpha > 24, band[index] > 128, band[index + 1] < 100 { count += 1 }
            index += 4
        }
        return count
    }

    // MARK: - Underline

    /// "aaaa" has no descenders: every red pixel below the baseline is
    /// the underline itself.
    func testUnderlineDrawsBelowBaseline() throws {
        let underlined = layout(text("aaaa", attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: red,
        ]))
        XCTAssertTrue(underlined.hasDecorations)
        let canvas = try PixelCanvas(
            layout: underlined, canvas: CGSize(width: 100, height: 40), point: .zero, scale: 2
        )
        let baseline = underlined.lines[0].position.y
        XCTAssertGreaterThan(redInk(canvas, fromY: baseline + 0.5, toY: baseline + 4), 0,
                             "underline band below the baseline must contain red ink")
        XCTAssertEqual(redInk(canvas, fromY: 0, toY: baseline - 8), 0,
                       "no red ink far above the baseline")
    }

    func testNoDecorationsMeansNoInkAndNoFlag() throws {
        let plain = layout(text("aaaa", attributes: [:]))
        XCTAssertFalse(plain.hasDecorations)
        let canvas = try PixelCanvas(
            layout: plain, canvas: CGSize(width: 100, height: 40), point: .zero, scale: 2
        )
        let baseline = plain.lines[0].position.y
        XCTAssertEqual(redInk(canvas, fromY: baseline + 0.5, toY: baseline + 4), 0)
    }

    /// Without an explicit underlineColor the line uses the run's
    /// foreground color.
    func testUnderlineColorFallsBackToForeground() throws {
        let underlined = layout(text("aaaa", attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): red,
        ]))
        let canvas = try PixelCanvas(
            layout: underlined, canvas: CGSize(width: 100, height: 40), point: .zero, scale: 2
        )
        let baseline = underlined.lines[0].position.y
        XCTAssertGreaterThan(redInk(canvas, fromY: baseline + 0.5, toY: baseline + 4), 0)
    }

    func testThickUnderlineDrawsMoreInkThanSingle() throws {
        func ink(_ style: NSUnderlineStyle) throws -> Int {
            let l = layout(text("aaaa", size: 32, attributes: [
                .underlineStyle: style.rawValue,
                .underlineColor: red,
            ]))
            let canvas = try PixelCanvas(
                layout: l, canvas: CGSize(width: 160, height: 60), point: .zero, scale: 2
            )
            let baseline = l.lines[0].position.y
            return redInk(canvas, fromY: baseline, toY: baseline + 10)
        }
        let single = try ink(.single)
        let thick = try ink(.thick)
        let double = try ink(.double)
        XCTAssertGreaterThan(single, 0)
        XCTAssertGreaterThan(thick, single)
        XCTAssertGreaterThan(double, single)
    }

    // MARK: - Strikethrough

    /// The strikethrough sits near half the x-height above the
    /// baseline — inside the glyph body, never below the baseline.
    func testStrikethroughCrossesGlyphBody() throws {
        let struck = layout(text("aaaa", attributes: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: red,
        ]))
        XCTAssertTrue(struck.hasDecorations)
        let canvas = try PixelCanvas(
            layout: struck, canvas: CGSize(width: 100, height: 40), point: .zero, scale: 2
        )
        let baseline = struck.lines[0].position.y
        XCTAssertGreaterThan(redInk(canvas, fromY: baseline - 8, toY: baseline - 1), 0,
                             "strikethrough must land inside the glyph body")
        XCTAssertEqual(redInk(canvas, fromY: baseline + 1, toY: baseline + 6), 0,
                       "nothing below the baseline for strikethrough")
    }

    // MARK: - Truncation token

    /// Decorations read run attributes, so a custom token's underline
    /// survives the truncated-line substitution.
    func testUnderlineOnTruncationToken() throws {
        let token = text("…more", attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: red,
        ])
        let body = text(String(repeating: "内容很长的文本。", count: 10), attributes: [:])
        let container = LoomTextContainer(
            size: CGSize(width: 200, height: 10_000),
            maximumNumberOfRows: 1,
            truncationToken: token
        )
        let l = LoomTextLayout(container: container, text: body)!
        XCTAssertTrue(l.isTruncated)
        XCTAssertTrue(l.hasDecorations)
        let tokenRect = try XCTUnwrap(l.truncationTokenRect)
        let canvas = try PixelCanvas(
            layout: l, canvas: CGSize(width: 200, height: 40), point: .zero, scale: 2
        )
        let baseline = l.lines[0].position.y
        var found = 0
        let band = canvas.rowBand(fromY: baseline + 0.5, toY: baseline + 4)
        var index = band.startIndex
        let rowWidth = canvas.pixelWidth * 4
        while index < band.endIndex {
            let offsetInRow = (index - band.startIndex) % rowWidth
            let x = CGFloat(offsetInRow / 4) / canvas.scale
            if x >= tokenRect.minX, x <= tokenRect.maxX,
                band[index + 3] > 24, band[index] > 128, band[index + 1] < 100 {
                found += 1
            }
            index += 4
        }
        XCTAssertGreaterThan(found, 0, "token underline must draw under the token rect")
    }

    // MARK: - Background strokes

    func testStrokeOnlyBackgroundDrawsOutlineNotFill() throws {
        let string = NSMutableAttributedString(attributedString: text("before TAG after", attributes: [:]))
        let range = NSRange(location: 7, length: 3)
        string.loom_setBackground(
            LoomTextBackground(strokeColor: green, strokeWidth: 2),
            range: range
        )
        let l = layout(string)
        let rect = l.rect(for: range)
        let canvas = try PixelCanvas(
            layout: l, canvas: CGSize(width: 400, height: 40), point: .zero, scale: 2
        )
        func greenAt(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let px = Int(x * canvas.scale), py = Int(y * canvas.scale)
            guard px >= 0, py >= 0, px < canvas.pixelWidth, py < canvas.pixelHeight else { return false }
            let base = (py * canvas.pixelWidth + px) * 4
            return canvas.pixels[base + 3] > 24 && canvas.pixels[base + 1] > canvas.pixels[base]
        }
        XCTAssertTrue(greenAt(rect.minX + 1, rect.midY), "left edge must be stroked")
        XCTAssertTrue(greenAt(rect.maxX - 1, rect.midY), "right edge must be stroked")
        // Center: interior of a glyph-free gap — sample just inside the
        // top edge below the stroke instead of a glyph area.
        XCTAssertFalse(greenAt(rect.midX, rect.minY + rect.height / 2 + 0.1) &&
                       greenAt(rect.midX - 1, rect.midY) &&
                       greenAt(rect.midX + 1, rect.midY),
                       "interior must not be filled edge to edge")
    }

    func testFillAndStrokeCombine() throws {
        let string = NSMutableAttributedString(attributedString: text("before TAG after", attributes: [:]))
        let range = NSRange(location: 7, length: 3)
        string.loom_setBackground(
            LoomTextBackground(fillColor: green, strokeColor: red, strokeWidth: 2, cornerRadius: 4),
            range: range
        )
        let l = layout(string)
        let rect = l.rect(for: range)
        let canvas = try PixelCanvas(
            layout: l, canvas: CGSize(width: 400, height: 40), point: .zero, scale: 2
        )
        // Fill somewhere inside; red stroke on the vertical edge midline.
        var greenFound = false
        for x in stride(from: rect.minX + 3, to: rect.maxX - 3, by: 1) {
            let px = Int(x * canvas.scale), py = Int(rect.midY * canvas.scale)
            let base = (py * canvas.pixelWidth + px) * 4
            if canvas.pixels[base + 3] > 24, canvas.pixels[base + 1] > 128, canvas.pixels[base] < 100 {
                greenFound = true
                break
            }
        }
        XCTAssertTrue(greenFound, "fill must survive alongside the stroke")
        let edgePx = Int((rect.minX + 1) * canvas.scale)
        let edgePy = Int(rect.midY * canvas.scale)
        let edgeBase = (edgePy * canvas.pixelWidth + edgePx) * 4
        XCTAssertTrue(
            canvas.pixels[edgeBase + 3] > 24 && canvas.pixels[edgeBase] > 128,
            "stroke must draw over the fill at the edge"
        )
    }
}
