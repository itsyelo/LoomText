//
//  LoomLabel.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

#if canImport(UIKit)
import UIKit

/// A `UILabel`-style view that renders a precomputed ``LoomTextLayout``.
///
/// **Direct mode** (the primary mode): assign ``textLayout`` built on a
/// background thread — typically the same layout Loom measured with —
/// and the label only blits. No typesetting happens on the main thread,
/// and measurement and rendering share one source of truth.
///
/// **Convenience mode**: assign ``attributedText`` and the label typesets
/// internally (synchronously, on the main thread) against its current
/// bounds, mirroring `UILabel` ergonomics for standalone use. The two
/// modes produce pixel-identical output for equal container sizes.
///
/// Direct-mode contract: the layout's container size is authoritative.
/// Changing the label's frame does not re-typeset — Loom (or the caller)
/// is responsible for providing a layout that matches the frame it
/// assigns.
public final class LoomLabel: UIView {

    // MARK: - Async rendering

    public override class var layerClass: AnyClass { LoomAsyncLayer.self }

    private var asyncLayer: LoomAsyncLayer { layer as! LoomAsyncLayer }

    /// Whether content renders on a background queue (default `true`).
    /// The synchronous path produces pixel-identical output on the main
    /// thread — useful for tests and screenshots.
    public var displaysAsynchronously: Bool {
        get { asyncLayer.displaysAsynchronously }
        set { asyncLayer.displaysAsynchronously = newValue }
    }

    // MARK: - Direct mode

    /// The precomputed layout to render. Setting this switches the label
    /// to direct mode and discards any `attributedText`.
    public var textLayout: LoomTextLayout? {
        get { layoutStorage }
        set {
            internalText = nil
            lastBuiltSize = .zero
            layoutStorage = newValue
            invalidateIntrinsicContentSize()
            invalidateAccessibilityElements()
            layer.setNeedsDisplay()
        }
    }

    // MARK: - Convenience mode

    /// Text to typeset internally against the current bounds. Setting
    /// this switches the label to convenience mode.
    public var attributedText: NSAttributedString? {
        get { internalText ?? layoutStorage?.text }
        set {
            internalText = newValue?.copy() as? NSAttributedString
            rebuildInternalLayout(force: true)
        }
    }

    /// Maximum number of rows in convenience mode. `0` means unlimited.
    /// Ignored in direct mode — the layout's container already encodes it.
    public var numberOfLines: Int = 0 {
        didSet {
            guard numberOfLines != oldValue, internalText != nil else { return }
            rebuildInternalLayout(force: true)
        }
    }

    // MARK: - Highlight interaction

    /// Signature for highlight callbacks: (label, text, highlight range,
    /// union rect of the range in label coordinates).
    ///
    /// For inline highlights, `text` is the layout's full string and
    /// `range` indexes into it. For truncation-token highlights
    /// ("…more"), `text` is the *token* string, `range` indexes into the
    /// token, and the rect is ``LoomTextLayout/truncationTokenRect`` —
    /// route on the highlight's `userInfo`.
    public typealias HighlightAction = (LoomLabel, NSAttributedString, NSRange, CGRect) -> Void

    /// Called when a ``LoomTextHighlight`` range is tapped.
    public var highlightTapAction: HighlightAction?

    /// Called when a ``LoomTextHighlight`` range is long-pressed.
    public var highlightLongPressAction: HighlightAction?

    /// How long a press must hold to count as a long press.
    public var longPressDuration: TimeInterval = 0.5

    /// Movement beyond this distance cancels the highlight (the touch is
    /// handed to scrolling).
    private static let highlightMoveCancelDistance: CGFloat = 9

    // MARK: - Private state

    private var layoutStorage: LoomTextLayout?
    private var internalText: NSAttributedString?
    private var lastBuiltSize: CGSize = .zero

    private var pressedLayout: LoomTextLayout?
    private var mountedAttachmentViews: [(view: UIView, attachment: LoomTextAttachment)] = []
    private var mountedAttachmentLayers: [CALayer] = []
    var cachedAccessibilityElements: [Any]?
    var trackedHighlight: (highlight: LoomTextHighlight, range: NSRange)?
    var trackedHighlightIsToken = false
    private var touchBeganPoint: CGPoint = .zero
    private var longPressTimer: Timer?
    private var longPressFired = false
    private var wasDisplayingAsynchronously = true

    // MARK: - Lifecycle

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.needsDisplayOnBoundsChange = true
        if #available(iOS 17.0, *) {
            registerForTraitChanges(
                [UITraitUserInterfaceStyle.self, UITraitDisplayGamut.self, UITraitAccessibilityContrast.self]
            ) { (self: LoomLabel, _) in
                self.layer.setNeedsDisplay()
            }
        }
    }

    /// Dynamic colors are resolved at draw time against the traits
    /// captured with each display task, so an appearance change requires
    /// a redraw of the cached bitmap. iOS 17+ uses the registration API;
    /// this override covers iOS 14–16.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) {
            if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
                layer.setNeedsDisplay()
            }
        }
    }

    // MARK: - UIView

    public override func layoutSubviews() {
        super.layoutSubviews()
        rebuildInternalLayout(force: false)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scale = window?.screen.scale, scale > 0 {
            contentScaleFactor = scale
        }
    }

    /// Direct mode reports the layout's bounding size. Convenience mode
    /// reports the last internally built layout (zero before the first
    /// layout pass — use ``sizeThatFits(_:)`` to measure up front).
    public override var intrinsicContentSize: CGSize {
        layoutStorage?.textBoundingSize ?? .zero
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        if let text = internalText {
            let container = LoomTextContainer(
                size: CGSize(
                    width: size.width > 0 ? size.width : LoomTextLayout.maxSize.width,
                    height: size.height > 0 ? size.height : LoomTextLayout.maxSize.height
                ),
                maximumNumberOfRows: numberOfLines
            )
            return LoomTextLayout(container: container, text: text)?.textBoundingSize ?? .zero
        }
        return layoutStorage?.textBoundingSize ?? .zero
    }

    // MARK: - Touch handling (highlight)

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Ignore additional touches while already tracking one — a second
        // began must not clobber the tracked state or the async flag.
        guard trackedHighlight == nil, let touch = touches.first, let layout = layoutStorage else {
            super.touchesBegan(touches, with: event)
            return
        }
        let point = touch.location(in: self)
        let isToken: Bool
        let hit: (highlight: LoomTextHighlight, range: NSRange)
        if let inline = layout.highlight(at: point) {
            hit = inline
            isToken = false
        } else if let token = layout.truncationTokenHighlight(at: point) {
            hit = token
            isToken = true
        } else {
            super.touchesBegan(touches, with: event)
            return
        }
        trackedHighlight = hit
        trackedHighlightIsToken = isToken
        touchBeganPoint = point
        longPressFired = false
        showPressedState(for: hit, isToken: isToken)
        startLongPressTimer()
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedHighlight != nil, let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }
        let point = touch.location(in: self)
        let distance = hypot(point.x - touchBeganPoint.x, point.y - touchBeganPoint.y)
        if distance > Self.highlightMoveCancelDistance {
            cancelHighlightTracking()
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let hit = trackedHighlight else {
            super.touchesEnded(touches, with: event)
            return
        }
        let fired = longPressFired
        let isToken = trackedHighlightIsToken
        let layout = layoutStorage
        cancelHighlightTracking()
        if !fired, let layout, let touch = touches.first {
            // Only fire when the finger lifts on the highlight.
            let point = touch.location(in: self)
            if let payload = tapPayload(for: hit, isToken: isToken, at: point, in: layout) {
                highlightTapAction?(self, payload.text, payload.range, payload.rect)
            }
        }
    }

    /// For inline highlights the payload is (layout text, range in text,
    /// union rect). For truncation-token highlights it is (token string,
    /// range in token, token rect) — documented on `HighlightAction`.
    private func tapPayload(
        for hit: (highlight: LoomTextHighlight, range: NSRange),
        isToken: Bool,
        at point: CGPoint,
        in layout: LoomTextLayout
    ) -> (text: NSAttributedString, range: NSRange, rect: CGRect)? {
        if isToken {
            guard let endHit = layout.truncationTokenHighlight(at: point),
                  endHit.highlight === hit.highlight,
                  let token = layout.resolvedTruncationToken,
                  let rect = layout.truncationTokenRect
            else { return nil }
            return (token, hit.range, rect)
        }
        guard let endHit = layout.highlight(at: point), endHit.highlight === hit.highlight else { return nil }
        return (layout.text, hit.range, layout.rect(for: hit.range))
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if trackedHighlight != nil {
            cancelHighlightTracking()
        } else {
            super.touchesCancelled(touches, with: event)
        }
    }

    private func startLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hit = self.trackedHighlight, let layout = self.layoutStorage else { return }
                self.longPressFired = true
                if self.trackedHighlightIsToken {
                    if let token = layout.resolvedTruncationToken, let rect = layout.truncationTokenRect {
                        self.highlightLongPressAction?(self, token, hit.range, rect)
                    }
                } else {
                    self.highlightLongPressAction?(self, layout.text, hit.range, layout.rect(for: hit.range))
                }
                self.cancelHighlightTracking()
            }
        }
    }

    func showPressedState(for hit: (highlight: LoomTextHighlight, range: NSRange), isToken: Bool = false) {
        guard let layout = layoutStorage else { return }
        if isToken {
            guard let token = layout.resolvedTruncationToken?.mutableCopy() as? NSMutableAttributedString
            else { return }
            token.addAttributes(hit.highlight.attributes, range: hit.range)
            var container = layout.container
            container.truncationToken = token
            pressedLayout = LoomTextLayout(container: container, text: layout.text)
        } else {
            guard let pressedText = layout.text.mutableCopy() as? NSMutableAttributedString else { return }
            pressedText.addAttributes(hit.highlight.attributes, range: hit.range)
            pressedLayout = LoomTextLayout(container: layout.container, text: pressedText)
        }
        // Pressed feedback must be instant: render synchronously while
        // the finger is down (YYLabel does the same).
        wasDisplayingAsynchronously = displaysAsynchronously
        displaysAsynchronously = false
        layer.setNeedsDisplay()
        layer.displayIfNeeded()
    }

    func cancelHighlightTracking() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        guard trackedHighlight != nil else { return }
        trackedHighlight = nil
        trackedHighlightIsToken = false
        pressedLayout = nil
        layer.setNeedsDisplay()
        layer.displayIfNeeded()
        displaysAsynchronously = wasDisplayingAsynchronously
    }

    // MARK: - Internal layout (convenience mode)

    private func rebuildInternalLayout(force: Bool) {
        guard let text = internalText else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            if force {
                layoutStorage = nil
                lastBuiltSize = .zero
                invalidateIntrinsicContentSize()
                layer.setNeedsDisplay()
            }
            return
        }
        if !force, size == lastBuiltSize { return }
        lastBuiltSize = size
        let container = LoomTextContainer(size: size, maximumNumberOfRows: numberOfLines)
        layoutStorage = LoomTextLayout(container: container, text: text)
        invalidateIntrinsicContentSize()
        invalidateAccessibilityElements()
        layer.setNeedsDisplay()
    }
}

// MARK: - LoomAsyncLayerDelegate

extension LoomLabel: LoomAsyncLayerDelegate {
    public func newAsyncDisplayTask() -> LoomAsyncLayerDisplayTask {
        var task = LoomAsyncLayerDisplayTask()
        // Every pass unmounts stale attachment views/layers, including
        // the empty pass that clears contents on textLayout = nil.
        task.willDisplay = { [weak self] _ in
            self?.unmountAttachments()
        }
        guard let layout = pressedLayout ?? layoutStorage, !layout.lines.isEmpty else { return task }
        task.traitCollection = traitCollection
        // The layout is immutable and Sendable — the whole point of the
        // pipeline: the render closure owns everything it needs.
        task.display = { context, size, isCancelled in
            layout.draw(in: context, size: size, cancel: isCancelled)
        }
        if !layout.attachments.isEmpty {
            task.didDisplay = { [weak self] _, finished in
                guard finished, let self,
                      (self.pressedLayout ?? self.layoutStorage) === layout
                else { return }
                self.mountAttachments(of: layout)
            }
        }
        return task
    }

    private func unmountAttachments() {
        for (view, attachment) in mountedAttachmentViews {
            view.removeFromSuperview()
            // Recycle hook: pools take their view back here.
            attachment.onViewUnmounted?(view)
        }
        mountedAttachmentLayers.forEach { $0.removeFromSuperlayer() }
        mountedAttachmentViews.removeAll()
        mountedAttachmentLayers.removeAll()
    }

    private func mountAttachments(of layout: LoomTextLayout) {
        for (index, attachment) in layout.attachments.enumerated() {
            let rect = layout.attachmentRects[index]
            if let provider = attachment.viewProvider {
                // Called at every mount: the closure decides ownership —
                // memoized instance (persistent animation state) or an
                // app-side pool dequeue (O(visible) live views).
                let view = provider()
                addSubview(view)
                view.frame = rect
                mountedAttachmentViews.append((view, attachment))
            } else if let view = attachment.content as? UIView {
                addSubview(view)
                view.frame = rect
                mountedAttachmentViews.append((view, attachment))
            } else if let contentLayer = attachment.content as? CALayer {
                layer.addSublayer(contentLayer)
                contentLayer.frame = rect
                mountedAttachmentLayers.append(contentLayer)
            }
        }
    }
}
#endif
