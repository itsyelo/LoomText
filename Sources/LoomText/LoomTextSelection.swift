//
//  LoomTextSelection.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Read-only text selection (WeChat/Telegram style): long-press to
//  select, drag lollipop handles to adjust, iOS 16+. Selection chrome
//  is a main-thread overlay ABOVE the rendered bitmap — it never
//  participates in the async render pipeline, so dragging at 60 Hz
//  costs two shape-layer updates, not a re-render.
//

#if canImport(UIKit)
import UIKit

/// Where a fresh selection starts when the user long-presses.
@available(iOS 16.0, *)
public enum LoomTextSelectionInitialRange: Sendable {
    /// Select all selectable text — chat-bubble ergonomics.
    case all
    /// Select the locale-aware word under the finger.
    case word
}

// MARK: - Controller

/// Owns the selection state and chrome for one ``LoomLabel``: the
/// tinted range overlay, the two drag handles, their gestures, and the
/// clear triggers. Created lazily when `isTextSelectionEnabled` is set.
@available(iOS 16.0, *)
@MainActor
final class LoomTextSelectionController: NSObject {

    private unowned let label: LoomLabel

    var initialRange: LoomTextSelectionInitialRange = .all
    var didChange: ((NSRange?) -> Void)?

    private(set) var selectedRange: NSRange? {
        didSet {
            guard selectedRange != oldValue else { return }
            updateChrome()
            didChange?(selectedRange)
        }
    }

    var isActive: Bool { selectedRange != nil }

    private let overlay = LoomTextSelectionOverlayView()
    private var currentRects: [CGRect] = []

    // Long-press tracking before a selection exists.
    private(set) var isTrackingPress = false
    private var pressPoint: CGPoint = .zero
    private var pressTimer: Timer?

    // Handle drag: the fixed end of the selection, as a UTF-16 index.
    private var dragAnchor: Int?
    private var observedScrollPan: UIPanGestureRecognizer?
    private var dismissTap: UITapGestureRecognizer?

    private var handlePans: [UIPanGestureRecognizer] = []

    init(label: LoomLabel) {
        self.label = label
        super.init()
        for handle in [overlay.startHandle, overlay.endHandle] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            handle.addGestureRecognizer(pan)
            handlePans.append(pan)
        }
    }

    // MARK: Touch routing (called from LoomLabel's touches overrides)

    /// Returns `true` when the controller consumed the touch.
    func handleTouchesBegan(at point: CGPoint) -> Bool {
        if isActive {
            // Touches on a handle reach the label through the responder
            // chain (plain UIViews forward touchesBegan) — they belong
            // to the pan, never to dismissal. A tap inside the selection
            // is menu territory (Task 17); anywhere else dismisses.
            if !selectionContains(point), !handleHitTest(point) { clear() }
            return true
        }
        guard label.textLayout != nil else { return false }
        isTrackingPress = true
        pressPoint = point
        startPressTimer()
        return true
    }

    func handleTouchesMoved(to point: CGPoint) {
        guard isTrackingPress else { return }
        let distance = hypot(point.x - pressPoint.x, point.y - pressPoint.y)
        if distance > 9 { cancelPressTracking() }
    }

    func handleTouchesEnded() { cancelPressTracking() }
    func handleTouchesCancelled() { cancelPressTracking() }

    private func startPressTimer() {
        pressTimer?.invalidate()
        pressTimer = Timer.scheduledTimer(withTimeInterval: label.longPressDuration, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isTrackingPress else { return }
                let point = self.pressPoint
                self.cancelPressTracking()
                self.beginSelection(at: point)
            }
        }
    }

    private func cancelPressTracking() {
        pressTimer?.invalidate()
        pressTimer = nil
        isTrackingPress = false
    }

    // MARK: Selection lifecycle

    func beginSelection(at point: CGPoint) {
        guard let layout = label.textLayout else { return }
        let range: NSRange?
        switch initialRange {
        case .all:
            range = layout.normalizedSelectionRange(for: layout.selectableRange)
        case .word:
            range = layout.characterIndex(at: point).flatMap { layout.wordRange(at: $0) }
        }
        guard let range else { return }
        attachChrome()
        UISelectionFeedbackGenerator().selectionChanged()
        selectedRange = range
        observeEnclosingScrollView()
        installDismissTap()
    }

    func selectAll() {
        guard let layout = label.textLayout,
              let range = layout.normalizedSelectionRange(for: layout.selectableRange)
        else { return }
        attachChrome()
        selectedRange = range
        observeEnclosingScrollView()
        installDismissTap()
    }

    func clear() {
        cancelPressTracking()
        dragAnchor = nil
        unobserveScrollView()
        removeDismissTap()
        selectedRange = nil
    }

    /// The backing layout was swapped — old indices are meaningless.
    func layoutDidChange() {
        if isActive || isTrackingPress { clear() }
    }

    /// Disabling selection: clear state and remove the chrome entirely.
    func tearDown() {
        clear()
        overlay.removeFromSuperview()
    }

    // MARK: Handle dragging (internal entry points so tests can drive)

    func beginHandleDrag(isStart: Bool) {
        guard let range = selectedRange else { return }
        dragAnchor = isStart ? range.location + range.length : range.location
    }

    func updateHandleDrag(to point: CGPoint) {
        guard let anchor = dragAnchor,
              let layout = label.textLayout,
              let index = layout.characterIndex(at: point)
        else { return }
        let lower = min(anchor, index)
        let upper = max(anchor, index)
        guard let updated = layout.normalizedSelectionRange(
            for: NSRange(location: lower, length: upper - lower)
        ) else { return } // zero-length mid-drag: keep the last valid range
        selectedRange = updated
    }

    func endHandleDrag() {
        dragAnchor = nil
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: label)
        switch pan.state {
        case .began:
            beginHandleDrag(isStart: pan.view === overlay.startHandle)
        case .changed:
            updateHandleDrag(to: point)
        case .ended, .cancelled, .failed:
            endHandleDrag()
        default:
            break
        }
    }

    // MARK: Chrome

    private func attachChrome() {
        if overlay.superview !== label {
            overlay.frame = label.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.addSubview(overlay)
        }
        label.bringSubviewToFront(overlay)
    }

    /// Attachment remounts add subviews above the overlay — restack.
    func bringChromeToFront() {
        guard overlay.superview === label else { return }
        label.bringSubviewToFront(overlay)
    }

    private func updateChrome() {
        guard let range = selectedRange, let layout = label.textLayout else {
            currentRects = []
            overlay.isHidden = true
            return
        }
        currentRects = layout.selectionRects(for: range)
        overlay.isHidden = currentRects.isEmpty
        overlay.update(rects: currentRects)
    }

    func selectionContains(_ point: CGPoint) -> Bool {
        currentRects.contains { $0.contains(point) }
    }

    /// Expanded hit-test for the handle knobs that poke outside the
    /// label bounds (first/last line). Called from `LoomLabel.point(inside:)`.
    func handleHitTest(_ point: CGPoint) -> Bool {
        guard isActive, overlay.superview === label else { return false }
        return overlay.expandedHandleContains(overlay.convert(point, from: label))
    }

    var overlayForTesting: UIView { overlay }

    // MARK: Scroll dismissal

    private func observeEnclosingScrollView() {
        guard observedScrollPan == nil else { return }
        var ancestor = label.superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView else { return }
        scroll.panGestureRecognizer.addTarget(self, action: #selector(scrollPanChanged(_:)))
        observedScrollPan = scroll.panGestureRecognizer
        // The scroll pan is greedy: without a failure requirement it
        // recognizes first, cancels the handle pan, and our own
        // clear-on-scroll fires. Touches not on a handle fail the
        // handle pans instantly, so scrolling elsewhere is unaffected.
        // (Requirements are permanent, but hidden handles receive no
        // touches — zero impact while selection is inactive.)
        for pan in handlePans {
            scroll.panGestureRecognizer.require(toFail: pan)
        }
    }

    private func unobserveScrollView() {
        observedScrollPan?.removeTarget(self, action: #selector(scrollPanChanged(_:)))
        observedScrollPan = nil
    }

    @objc private func scrollPanChanged(_ pan: UIPanGestureRecognizer) {
        // A handle drag in flight must never be mistaken for scrolling.
        if pan.state == .began, dragAnchor == nil { clear() }
    }

    // MARK: Tap-anywhere dismissal

    /// Taps on sibling views (another card, another bubble) must also
    /// dismiss — the label's own touch handling never sees those. A
    /// non-cancelling window-level tap covers the whole screen while a
    /// selection is active.
    private func installDismissTap() {
        guard dismissTap == nil, let window = label.window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(windowTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        dismissTap = tap
    }

    private func removeDismissTap() {
        dismissTap?.view?.removeGestureRecognizer(dismissTap!)
        dismissTap = nil
    }

    @objc private func windowTapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: label)
        if !selectionContains(point), !handleHitTest(point) { clear() }
    }
}

@available(iOS 16.0, *)
extension LoomTextSelectionController: UIGestureRecognizerDelegate {
    /// The dismiss tap observes; it must never starve other recognizers.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Overlay

/// Draws the tinted selection rects and hosts the two handles. Touches
/// pass through everywhere except the handles.
@available(iOS 16.0, *)
@MainActor
final class LoomTextSelectionOverlayView: UIView {

    let startHandle = LoomTextSelectionHandleView(knobOnTop: true)
    let endHandle = LoomTextSelectionHandleView(knobOnTop: false)
    private let fillLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        layer.addSublayer(fillLayer)
        addSubview(startHandle)
        addSubview(endHandle)
        applyFillColor()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func update(rects: [CGRect]) {
        let path = CGMutablePath()
        for rect in rects where rect.width > 0 && rect.height > 0 {
            path.addRect(rect)
        }
        fillLayer.path = path
        if let first = rects.first, let last = rects.last {
            startHandle.isHidden = false
            endHandle.isHidden = false
            startHandle.place(caretX: first.minX, lineTop: first.minY, lineHeight: first.height)
            endHandle.place(caretX: last.maxX, lineTop: last.minY, lineHeight: last.height)
        } else {
            startHandle.isHidden = true
            endHandle.isHidden = true
        }
    }

    private func applyFillColor() {
        fillLayer.fillColor = tintColor.withAlphaComponent(0.2)
            .resolvedColor(with: traitCollection).cgColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyFillColor()
    }

    /// Dynamic tint must re-resolve when the appearance flips; the
    /// override pattern mirrors LoomLabel (registration API on 17+ is
    /// not needed here — this class is instantiated on demand and the
    /// deprecated override still fires on 16).
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            applyFillColor()
        }
    }

    /// Touches fall through to the label except on a handle.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for handle in [startHandle, endHandle] where !handle.isHidden {
            if handle.point(inside: convert(point, to: handle), with: event) {
                return handle
            }
        }
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expandedHandleContains(point) || bounds.contains(point)
    }

    func expandedHandleContains(_ point: CGPoint) -> Bool {
        for handle in [startHandle, endHandle] where !handle.isHidden {
            if handle.point(inside: convert(point, to: handle), with: nil) { return true }
        }
        return false
    }
}

// MARK: - Handle

/// One lollipop grabber: a 2pt stem spanning the line height plus a
/// round knob — above the stem at the selection start, below it at the
/// end (UIKit convention).
@available(iOS 16.0, *)
@MainActor
final class LoomTextSelectionHandleView: UIView {

    static let knobDiameter: CGFloat = 10
    static let stemWidth: CGFloat = 2
    /// Extra touch slop around the visual bounds.
    static let touchSlop: CGFloat = 22

    let knobOnTop: Bool
    private let stem = UIView()
    private let knob = UIView()

    init(knobOnTop: Bool) {
        self.knobOnTop = knobOnTop
        super.init(frame: .zero)
        isHidden = true
        knob.layer.cornerRadius = Self.knobDiameter / 2
        addSubview(stem)
        addSubview(knob)
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTint()
    }

    private func applyTint() {
        stem.backgroundColor = tintColor
        knob.backgroundColor = tintColor
    }

    /// Positions the handle against a caret edge given in the
    /// superview's coordinates.
    func place(caretX: CGFloat, lineTop: CGFloat, lineHeight: CGFloat) {
        let knobD = Self.knobDiameter
        let width = knobD
        let height = lineHeight + knobD
        let originY = knobOnTop ? lineTop - knobD : lineTop
        frame = CGRect(x: caretX - width / 2, y: originY, width: width, height: height)
        let stemX = (width - Self.stemWidth) / 2
        if knobOnTop {
            knob.frame = CGRect(x: 0, y: 0, width: knobD, height: knobD)
            stem.frame = CGRect(x: stemX, y: knobD, width: Self.stemWidth, height: lineHeight)
        } else {
            stem.frame = CGRect(x: stemX, y: 0, width: Self.stemWidth, height: lineHeight)
            knob.frame = CGRect(x: 0, y: lineHeight, width: knobD, height: knobD)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchSlop, dy: -Self.touchSlop).contains(point)
    }
}
#endif
