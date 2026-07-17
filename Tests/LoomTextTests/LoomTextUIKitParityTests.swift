//
//  LoomTextUIKitParityTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Phase 0 gate, UIKit half: UILabel cross-checks and Dynamic Type.
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import LoomText

@MainActor
final class LoomTextUIKitParityTests: XCTestCase {

    private let sample =
        "Feed cell body text used for cross-engine comparison. 中英文混排以及 emoji 🎉 一并覆盖，保证行数足够多。"

    /// UIFont attributes — the path real apps use (bridged to CTFont by
    /// CoreText). The rest of the matrix uses CTFont directly.
    private func uiAttr(_ string: String, font: UIFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: UIColor.black])
    }

    func testUIFontAttributePathInkContainment() throws {
        let text = uiAttr(sample, font: .systemFont(ofSize: 17))
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 180, height: 10_000), text: text)
        )
        XCTAssertGreaterThan(layout.rowCount, 2)
        let claimed = layout.textBoundingSize
        let margin: CGFloat = 20
        let canvas = CGSize(width: claimed.width + margin * 2, height: claimed.height + margin * 2)
        let rendered = try PixelCanvas(
            layout: layout, canvas: canvas, point: CGPoint(x: margin, y: margin), scale: 3
        )
        let ink = try XCTUnwrap(rendered.inkRect)
        let box = CGRect(x: margin, y: margin, width: claimed.width, height: claimed.height)
            .insetBy(dx: -2, dy: 0) // emoji in sample: horizontal bitmap bleed allowed
        XCTAssertTrue(box.contains(ink), "ink \(ink) escapes \(box)")
    }

    private func uiLabelDelta(text: NSAttributedString, width: CGFloat) throws -> (delta: CGFloat, rows: Int) {
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = text
        let labelSize = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: width, height: 10_000), text: text)
        )
        return (abs(labelSize.height - layout.textBoundingSize.height), layout.rowCount)
    }

    /// Documents the cross-engine relationship rather than demanding
    /// equality: UILabel sizes with TextKit (font.lineHeight based, per
    /// line pixel rounding), LoomText with CoreText line-bounds union
    /// (no trailing leading). Measured on iOS 18.5 / iPhone 16 Pro:
    /// pure-Latin SF 17 ≈ sub-pt total; CJK+emoji fallback ≈ 0.53pt/row.
    /// These are tripwires — a jump means an engine changed underneath.
    func testUILabelHeightDeltaLatin() throws {
        let latin = uiAttr(
            "Feed cell body text used for cross engine comparison with several wrapping rows of plain Latin.",
            font: .systemFont(ofSize: 17)
        )
        let (delta, rows) = try uiLabelDelta(text: latin, width: 180)
        XCTAssertGreaterThan(rows, 2)
        XCTAssertLessThanOrEqual(delta, 1.5, "pure-Latin drift: \(delta)pt over \(rows) rows")
    }

    func testUILabelHeightDeltaMixedScript() throws {
        let (delta, rows) = try uiLabelDelta(text: uiAttr(sample, font: .systemFont(ofSize: 17)), width: 180)
        XCTAssertGreaterThan(rows, 2)
        // Fallback-font line heights (PingFang, Apple Color Emoji) differ
        // per engine by <1pt per row.
        XCTAssertLessThanOrEqual(
            delta, CGFloat(rows) * 1.0,
            "mixed-script drift: \(delta)pt over \(rows) rows"
        )
    }

    func testDynamicTypeSizesStayContained() throws {
        for category in [UIContentSizeCategory.large, .accessibilityLarge] {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let text = uiAttr("Dynamic Type row for category \(category.rawValue) with enough words to wrap.", font: font)
            let layout = try XCTUnwrap(
                LoomTextLayout(containerSize: CGSize(width: 200, height: 10_000), text: text)
            )
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
            XCTAssertTrue(box.contains(ink), "\(category.rawValue): ink \(ink) escapes \(box)")
        }
    }
}
#endif
