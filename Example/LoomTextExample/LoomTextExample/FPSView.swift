//
//  FPSView.swift
//  LoomTextExample
//
//  CADisplayLink-driven FPS HUD, shared by the Perf and Chat tabs.
//

import UIKit

final class FPSView: UILabel {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frameCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        textColor = .systemGreen
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        textAlignment = .center
        layer.cornerRadius = 6
        layer.masksToBounds = true
        text = " -- FPS "
        link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { link?.invalidate() }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        frameCount += 1
        let delta = link.timestamp - lastTimestamp
        guard delta >= 1 else { return }
        let fps = Double(frameCount) / delta
        frameCount = 0
        lastTimestamp = link.timestamp
        text = String(format: " %.0f FPS ", fps)
        textColor = fps > 55 ? .systemGreen : (fps > 45 ? .systemYellow : .systemRed)
    }
}
