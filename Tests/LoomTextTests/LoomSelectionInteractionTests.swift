//
//  LoomSelectionInteractionTests.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Task 16 — selection state machine on LoomLabel: enable/disable,
//  initial ranges, handle drags (driven through the controller's
//  internal entry points), and the clear triggers.
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import LoomText

@available(iOS 16.0, *)
@MainActor
final class LoomSelectionInteractionTests: XCTestCase {

    private func attr(_ string: String, size: CGFloat = 16) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: size)])
    }

    private func makeLabel(
        _ string: String = "Hello world selection",
        width: CGFloat = 300
    ) -> LoomLabel {
        let label = LoomLabel(frame: CGRect(x: 0, y: 0, width: width, height: 60))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 10_000), text: attr(string)
        )
        label.isTextSelectionEnabled = true
        return label
    }

    private func midPoint(of range: NSRange, in label: LoomLabel) -> CGPoint {
        let rect = label.textLayout!.rect(for: range)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - Enable / disable

    func testEnableDisableLifecycle() {
        let label = makeLabel()
        XCTAssertTrue(label.isTextSelectionEnabled)
        label.selectAll()
        XCTAssertNotNil(label.selectedRange)

        label.isTextSelectionEnabled = false
        XCTAssertFalse(label.isTextSelectionEnabled)
        XCTAssertNil(label.selectedRange)
        XCTAssertFalse(label.subviews.contains { $0 is LoomTextSelectionOverlayView })
    }

    func testDisabledLabelHasNoSelectionAPIEffect() {
        let label = LoomLabel()
        label.textLayout = LoomTextLayout(
            containerSize: CGSize(width: 100, height: 100), text: attr("hi")
        )
        label.selectAll() // no controller — must be a no-op, not a crash
        XCTAssertNil(label.selectedRange)
    }

    // MARK: - Initial range

    func testSelectAllCoversSelectableRange() {
        let label = makeLabel()
        var observed: [NSRange?] = []
        label.selectionDidChange = { observed.append($0) }
        label.selectAll()
        XCTAssertEqual(label.selectedRange, label.textLayout!.selectableRange)
        XCTAssertEqual(observed, [label.textLayout!.selectableRange])
    }

    func testBeginSelectionAllIsDefault() {
        let label = makeLabel()
        label.selectionController?.beginSelection(at: midPoint(of: NSRange(location: 0, length: 5), in: label))
        XCTAssertEqual(label.selectedRange, label.textLayout!.selectableRange)
    }

    func testBeginSelectionWordPicksWordUnderPoint() {
        let label = makeLabel("Hello world selection")
        label.selectionInitialRange = .word
        // Point inside "world" (6..<11).
        let point = midPoint(of: NSRange(location: 6, length: 5), in: label)
        label.selectionController?.beginSelection(at: point)
        XCTAssertEqual(label.selectedRange, NSRange(location: 6, length: 5))
    }

    // MARK: - Chrome

    func testOverlayAttachedTopmostAndPopulated() throws {
        let label = makeLabel()
        label.selectAll()
        let overlay = try XCTUnwrap(
            label.subviews.compactMap { $0 as? LoomTextSelectionOverlayView }.first
        )
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(label.subviews.last === overlay)
        XCTAssertFalse(overlay.startHandle.isHidden)
        XCTAssertFalse(overlay.endHandle.isHidden)
        // Start knob on top, end knob below (UIKit convention).
        XCTAssertTrue(overlay.startHandle.knobOnTop)
        XCTAssertFalse(overlay.endHandle.knobOnTop)
    }

    // MARK: - Handle drags

    func testDragEndHandleShrinksSelection() throws {
        let label = makeLabel("Hello world selection")
        label.selectAll()
        let controller = try XCTUnwrap(label.selectionController)
        controller.beginHandleDrag(isStart: false) // anchor = range start (0)
        // Drag the end onto the middle of "Hello".
        controller.updateHandleDrag(to: midPoint(of: NSRange(location: 2, length: 1), in: label))
        controller.endHandleDrag()
        let range = try XCTUnwrap(label.selectedRange)
        XCTAssertEqual(range.location, 0)
        XCTAssertLessThan(range.length, 6)
        XCTAssertGreaterThan(range.length, 0)
    }

    func testDragPastAnchorSwapsEnds() throws {
        let label = makeLabel("Hello world selection")
        let controller = try XCTUnwrap(label.selectionController)
        label.selectionInitialRange = .word
        controller.beginSelection(at: midPoint(of: NSRange(location: 6, length: 5), in: label)) // "world"
        XCTAssertEqual(label.selectedRange, NSRange(location: 6, length: 5))

        // Grab the START handle (anchor becomes the END = 11) and drag it
        // beyond the anchor into "selection" — the ends must swap.
        controller.beginHandleDrag(isStart: true)
        controller.updateHandleDrag(to: midPoint(of: NSRange(location: 14, length: 3), in: label))
        controller.endHandleDrag()
        let range = try XCTUnwrap(label.selectedRange)
        XCTAssertEqual(range.location, 11)
        XCTAssertGreaterThan(range.length, 0)
    }

    func testDragNeverSplitsZWJEmoji() throws {
        let family = "ab👨‍👩‍👧‍👦cd" // emoji cluster at (2, 11)
        let label = makeLabel(family)
        let controller = try XCTUnwrap(label.selectionController)
        label.selectAll()
        controller.beginHandleDrag(isStart: false) // anchor = 0
        // Target the middle of the emoji cluster.
        let midEmoji = midPoint(of: NSRange(location: 2, length: 11), in: label)
        controller.updateHandleDrag(to: midEmoji)
        controller.endHandleDrag()
        let range = try XCTUnwrap(label.selectedRange)
        let clusterEnd = 13
        XCTAssertTrue(
            range.length == 2 || range.location + range.length == clusterEnd,
            "selection must end at a cluster boundary, got \(range)"
        )
    }

    func testZeroLengthDragKeepsLastValidRange() throws {
        let label = makeLabel("Hello world")
        let controller = try XCTUnwrap(label.selectionController)
        label.selectionInitialRange = .word
        let helloMid = midPoint(of: NSRange(location: 0, length: 5), in: label)
        controller.beginSelection(at: helloMid)
        let before = label.selectedRange
        controller.beginHandleDrag(isStart: false) // anchor = 0
        // Drag the end back onto the anchor → zero length → keep previous.
        controller.updateHandleDrag(to: midPoint(of: NSRange(location: 0, length: 1), in: label))
        XCTAssertNotNil(label.selectedRange)
        XCTAssertEqual(label.selectedRange?.location, before?.location)
    }

    // MARK: - Clear triggers

    func testTapOutsideSelectionClears() throws {
        let label = makeLabel("Hello world selection")
        let controller = try XCTUnwrap(label.selectionController)
        label.selectionInitialRange = .word
        controller.beginSelection(at: midPoint(of: NSRange(location: 0, length: 5), in: label))
        XCTAssertNotNil(label.selectedRange)

        // Consume + clear: the tap lands on "selection", outside "Hello".
        let outside = midPoint(of: NSRange(location: 14, length: 3), in: label)
        XCTAssertTrue(controller.handleTouchesBegan(at: outside))
        XCTAssertNil(label.selectedRange)
    }

    func testTapInsideSelectionKeepsIt() throws {
        let label = makeLabel("Hello world selection")
        let controller = try XCTUnwrap(label.selectionController)
        label.selectAll()
        let inside = midPoint(of: NSRange(location: 6, length: 5), in: label)
        XCTAssertTrue(controller.handleTouchesBegan(at: inside))
        XCTAssertNotNil(label.selectedRange)
    }

    func testLayoutSwapClears() {
        let label = makeLabel()
        label.selectAll()
        XCTAssertNotNil(label.selectedRange)
        label.textLayout = LoomTextLayout(
            containerSize: CGSize(width: 300, height: 100), text: attr("new content")
        )
        XCTAssertNil(label.selectedRange)
    }

    func testLeavingWindowClears() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let label = makeLabel()
        window.addSubview(label)
        window.isHidden = false
        label.selectAll()
        XCTAssertNotNil(label.selectedRange)
        label.removeFromSuperview()
        XCTAssertNil(label.selectedRange)
    }

    func testClearSelectionAPIAndCallback() {
        let label = makeLabel()
        var observed: [NSRange?] = []
        label.selectionDidChange = { observed.append($0) }
        label.selectAll()
        label.clearSelection()
        XCTAssertNil(label.selectedRange)
        XCTAssertEqual(observed.count, 2)
        XCTAssertNil(observed.last!)
    }

    // MARK: - Menu & standard edit actions (Task 17)

    func testFirstResponderGatedOnActiveSelection() {
        let label = makeLabel()
        XCTAssertFalse(label.canBecomeFirstResponder)
        label.selectAll()
        XCTAssertTrue(label.canBecomeFirstResponder)
        label.clearSelection()
        XCTAssertFalse(label.canBecomeFirstResponder)
    }

    func testCanPerformActionMatrix() {
        let label = makeLabel("Hello world selection")
        // Inactive: nothing.
        XCTAssertFalse(label.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))

        // Partial selection: copy + select all.
        label.selectionInitialRange = .word
        label.selectionController?.beginSelection(at: midPoint(of: NSRange(location: 0, length: 5), in: label))
        XCTAssertTrue(label.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertTrue(label.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        // Unrelated actions are rejected while active.
        XCTAssertFalse(label.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))

        // Full selection: no select-all entry.
        label.selectAll()
        XCTAssertTrue(label.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertFalse(label.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
    }

    func testCopySelectionUsesPlainTextAndClears() {
        let label = makeLabel("Hello world selection")
        label.selectionInitialRange = .word
        label.selectionController?.beginSelection(at: midPoint(of: NSRange(location: 6, length: 5), in: label))
        // The default sink writes UIPasteboard.general, which hangs in a
        // scene-less test host — capture instead.
        var copied: [String] = []
        label.selectionController?.copySink = { copied.append($0) }
        label.copy(nil)
        XCTAssertEqual(copied, ["world"])
        XCTAssertNil(label.selectedRange)
    }

    func testSelectAllStandardActionExpandsSelection() {
        let label = makeLabel("Hello world selection")
        label.selectionInitialRange = .word
        label.selectionController?.beginSelection(at: midPoint(of: NSRange(location: 0, length: 5), in: label))
        label.selectAll(nil)
        XCTAssertEqual(label.selectedRange, label.textLayout!.selectableRange)
    }

    func testCopyStripsAttachmentPlaceholder() {
        let text = NSMutableAttributedString(string: "GIF ", attributes: [
            .font: UIFont.systemFont(ofSize: 16),
        ])
        text.append(.loom_attachmentString(
            content: UIImage(), contentSize: CGSize(width: 16, height: 16),
            alignTo: UIFont.systemFont(ofSize: 16)
        ))
        text.append(NSAttributedString(string: " done", attributes: [
            .font: UIFont.systemFont(ofSize: 16),
        ]))
        let label = LoomLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: CGSize(width: 300, height: 100), text: text)
        label.isTextSelectionEnabled = true
        label.selectAll()
        var copied: [String] = []
        label.selectionController?.copySink = { copied.append($0) }
        label.copy(nil)
        XCTAssertEqual(copied, ["GIF  done"])
    }

    func testAdditionalMenuItemsRoundTrip() {
        let label = makeLabel()
        label.additionalEditMenuItems = { range in
            [UIAction(title: "Forward \(range.length)") { _ in }]
        }
        label.selectAll()
        let items = label.selectionController?.additionalMenuItems?(label.selectedRange!)
        XCTAssertEqual(items?.count, 1)
    }

    // MARK: - Truncated layouts

    func testSelectAllStopsAtSelectableRangeWhenTruncated() {
        let text = String(repeating: "很长的中文内容测试文本。", count: 10)
        let label = LoomLabel(frame: CGRect(x: 0, y: 0, width: 160, height: 30))
        label.displaysAsynchronously = false
        let container = LoomTextContainer(
            size: CGSize(width: 160, height: 10_000), maximumNumberOfRows: 1
        )
        label.textLayout = LoomTextLayout(container: container, text: attr(text))
        label.isTextSelectionEnabled = true
        label.selectAll()
        XCTAssertEqual(label.selectedRange, label.textLayout!.selectableRange)
        XCTAssertLessThan(label.selectedRange!.length, label.textLayout!.visibleRange.length)
    }
}
#endif
