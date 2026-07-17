//
//  Stickers.swift
//  LoomTextExample
//
//  Animated stickers as inline attachments, loaded from real network
//  GIFs via SDWebImage. Two ownership flavors on top of LoomText's
//  view lifecycle hooks:
//
//  - Flavor A (Showcase): a memoized provider keeps one view instance,
//    so animation state survives re-display. O(attachments) views.
//  - Flavor B (Chat): `StickerViewPool` dequeues a view at mount and
//    takes it back on unmount — live view count stays O(visible) no
//    matter how many thousands of messages hold sticker descriptors.
//
//  Frame buffers are shared either way: SDWebImage caches the decoded
//  SDAnimatedImage per URL, so 10 000 messages using the same sticker
//  hold one frame buffer.
//

import LoomText
import SDWebImage
import UIKit

/// A sticker descriptor — pure value, safe to build on background
/// queues inside view models.
enum Sticker: String, CaseIterable {
    case earth
    case cradle
    case confetti

    /// Real network animations (long-lived, stable URLs).
    var url: URL {
        switch self {
        case .earth:
            return URL(string: "https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif")!
        case .cradle:
            return URL(string: "https://upload.wikimedia.org/wikipedia/commons/d/d3/Newtons_cradle_animation_book_2.gif")!
        case .confetti:
            return URL(string: "https://raw.githubusercontent.com/SDWebImage/SDWebImage/master/Tests/Tests/Images/TestImage.gif")!
        }
    }

    /// What the sticker copies as (and what VoiceOver falls back to).
    var altText: String {
        switch self {
        case .earth: return "[地球]"
        case .cradle: return "[牛顿摆]"
        case .confetti: return "[彩带]"
        }
    }
}

/// Flavor B: a reuse pool for animated sticker views. Live views scale
/// with what's on screen, not with message count.
@MainActor
final class StickerViewPool {
    static let shared = StickerViewPool()

    private var idle: [SDAnimatedImageView] = []
    private(set) var createdCount = 0
    private(set) var mountedCount = 0

    var statsDescription: String {
        "sticker views — mounted: \(mountedCount), pooled idle: \(idle.count), ever created: \(createdCount)"
    }

    func dequeue(for sticker: Sticker) -> UIView {
        let view: SDAnimatedImageView
        if let reused = idle.popLast() {
            view = reused
        } else {
            view = SDAnimatedImageView()
            view.contentMode = .scaleAspectFit
            view.autoPlayAnimatedImage = true
            view.clearBufferWhenStopped = true
            createdCount += 1
        }
        mountedCount += 1
        view.backgroundColor = UIColor.systemGray5 // placeholder while loading / offline
        view.sd_setImage(with: sticker.url) { image, _, _, _ in
            if image != nil { view.backgroundColor = .clear }
        }
        return view
    }

    func recycle(_ view: UIView) {
        guard let animated = view as? SDAnimatedImageView else { return }
        mountedCount -= 1
        animated.sd_cancelCurrentImageLoad()
        animated.image = nil
        idle.append(animated)
    }
}

extension NSAttributedString {

    /// Flavor B attachment: pool-backed animated sticker.
    static func pooledSticker(_ sticker: Sticker, size: CGSize, alignTo font: UIFont) -> NSAttributedString {
        .loom_attachmentString(
            viewProvider: { StickerViewPool.shared.dequeue(for: sticker) },
            onViewUnmounted: { StickerViewPool.shared.recycle($0) },
            contentSize: size,
            alignTo: font,
            altText: sticker.altText
        )
    }

    /// Flavor A attachment: one memoized animated view per attachment —
    /// animation state persists across re-displays.
    @MainActor
    static func persistentSticker(_ sticker: Sticker, size: CGSize, alignTo font: UIFont) -> NSAttributedString {
        let view = SDAnimatedImageView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = UIColor.systemGray5
        view.sd_setImage(with: sticker.url) { image, _, _, _ in
            if image != nil { view.backgroundColor = .clear }
        }
        return .loom_attachmentString(
            viewProvider: { view },
            contentSize: size,
            alignTo: font,
            altText: sticker.altText
        )
    }
}
