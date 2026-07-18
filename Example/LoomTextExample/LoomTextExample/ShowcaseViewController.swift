//
//  ShowcaseViewController.swift
//  LoomTextExample
//
//  Standalone LoomLabel feature gallery: expand/collapse via a tappable
//  truncation token, pressed highlights, inline attachments, async
//  toggle, dark mode.
//

import LoomText
import UIKit

final class ShowcaseViewController: UIViewController {

    private let stack = UIStackView()
    private let expandableLabel = LoomLabel()
    private var isExpanded = false
    private var collapsedLayout: LoomTextLayout?
    private var expandedLayout: LoomTextLayout?

    private let story = "LoomText 是 Loom 的姊妹渲染库：后台排版一次，测量与渲染共用同一份 "
        + "LoomTextLayout，主线程只剩位图提交。这段文字默认折叠为三行，点击右下角的"
        + "自定义截断标记即可展开——展开与折叠的前几行逐像素一致，不会发生任何跳动。"
        + "再次点击可以收起。The quick brown fox jumps over the lazy dog."

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "LoomText Showcase"
        view.backgroundColor = .systemBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        buildCards()
    }

    private func buildCards() {
        let width = UIScreen.main.bounds.width - 32

        // Card 1 — expand/collapse via tappable truncation token.
        stack.addArrangedSubview(header("截断 Token：点击「…全文」展开 / 点击「收起」折叠"))
        let body = DemoText.body(story)
        collapsedLayout = LoomTextLayout(
            container: LoomTextContainer(
                size: CGSize(width: width, height: 10_000),
                maximumNumberOfRows: 3,
                truncationToken: DemoText.expandToken()
            ),
            text: body
        )
        let expandedText = NSMutableAttributedString(attributedString: body)
        let collapse = NSMutableAttributedString(string: " 收起", attributes: [
            .font: DemoText.bodyFont,
            .foregroundColor: UIColor.systemBlue,
        ])
        collapse.loom_setHighlight(
            NSRange(location: 0, length: collapse.length),
            pressedAttributes: [.foregroundColor: UIColor.systemBlue.withAlphaComponent(0.4)],
            userInfo: ["action": "collapse"]
        )
        expandedText.append(collapse)
        expandedLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 10_000), text: expandedText
        )
        expandableLabel.textLayout = collapsedLayout
        expandableLabel.highlightTapAction = { [weak self] _, _, _, _ in
            self?.toggleExpanded()
        }
        // Long-press selects (token highlight has no long-press action,
        // so selection takes the long-press per the priority policy).
        expandableLabel.isTextSelectionEnabled = true
        stack.addArrangedSubview(expandableLabel)

        // Card 2 — pressed highlights.
        stack.addArrangedSubview(header("Highlight：@提及可点击，按下有态"))
        let mentionLabel = LoomLabel()
        let mentionBody = DemoText.body("和 @Yelo 一起看看链接高亮的按下反馈效果，长按也有独立回调。", mention: "@Yelo")
        mentionLabel.textLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 200), text: mentionBody
        )
        mentionLabel.highlightTapAction = { [weak self] _, _, _, _ in
            self?.showAlert("Tapped @Yelo")
        }
        mentionLabel.highlightLongPressAction = { [weak self] _, _, _, _ in
            self?.showAlert("Long-pressed @Yelo")
        }
        stack.addArrangedSubview(mentionLabel)

        // Card 3 — inline attachments.
        stack.addArrangedSubview(header("Attachment：内联图片与 UIView 徽章"))
        let attachmentLabel = LoomLabel()
        let attachmentText = NSMutableAttributedString(
            attributedString: DemoText.body("行内图片 ")
        )
        attachmentText.append(.loom_attachmentString(
            content: Self.solidImage(color: .systemOrange, size: CGSize(width: 20, height: 20)),
            contentSize: CGSize(width: 20, height: 20),
            alignTo: DemoText.bodyFont
        ))
        attachmentText.append(DemoText.body(" 与视图徽章 "))
        let badge = UIView()
        badge.backgroundColor = .systemGreen
        badge.layer.cornerRadius = 10
        badge.accessibilityLabel = "在线状态"
        attachmentText.append(.loom_attachmentString(
            content: badge,
            contentSize: CGSize(width: 20, height: 20),
            alignTo: DemoText.bodyFont
        ))
        attachmentText.append(DemoText.body(" 混排在同一行。"))
        attachmentLabel.textLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 300), text: attachmentText
        )
        stack.addArrangedSubview(attachmentLabel)

        // Card 3.5 — self-drawn decorations: underline, strikethrough,
        // and an outlined topic tag (CTLineDraw renders none of these).
        stack.addArrangedSubview(header("装饰线与边框：下划线、删除线、话题标签"))
        let decorationLabel = LoomLabel()
        let decoration = NSMutableAttributedString()
        decoration.append(NSAttributedString(string: "带下划线的链接", attributes: [
            .font: DemoText.bodyFont,
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        decoration.append(DemoText.body(" 原价 "))
        decoration.append(NSAttributedString(string: "¥199", attributes: [
            .font: DemoText.bodyFont,
            .foregroundColor: UIColor.secondaryLabel,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]))
        decoration.append(DemoText.body(" 现价 ¥99，话题 "))
        // Chip spacing recipe — each layer typesets:
        // outer regular spaces (in the neighbor strings) = margin;
        // inner NBSPs = padding inside the border, non-breaking so the
        // pad never wraps into an orphan fragment;
        // negative insets stay vertical-only (breathing, not layout).
        let topic = NSMutableAttributedString(string: "\u{00A0}#LoomText\u{00A0}", attributes: [
            .font: DemoText.bodyFont,
            .foregroundColor: UIColor.systemBlue,
        ])
        topic.loom_setBackground(
            LoomTextBackground(
                strokeColor: UIColor.systemBlue.cgColor,
                strokeWidth: 1,
                cornerRadius: 8,
                insets: LoomEdgeInsets(top: -1, left: 0, bottom: -1, right: 0)
            ),
            range: NSRange(location: 0, length: topic.length)
        )
        decoration.append(topic)
        decoration.append(DemoText.body(" 描边不填充。"))
        // Grown capsules borrow inter-line space: line spacing keeps
        // them off the previous line's underline. Edge bleed needs no
        // setup — ink overflow renders it outside the label bounds.
        let decorationParagraph = NSMutableParagraphStyle()
        decorationParagraph.lineSpacing = 5
        decoration.addAttribute(
            .paragraphStyle, value: decorationParagraph,
            range: NSRange(location: 0, length: decoration.length)
        )
        decorationLabel.textLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 300), text: decoration
        )
        stack.addArrangedSubview(decorationLabel)

        // Card 4 — animated stickers (flavor A: memoized provider, so
        // animation state persists across re-displays).
        stack.addArrangedSubview(header("动态表情：真实网络 GIF，view attachment 独立动画"))
        let stickerLabel = LoomLabel()
        let stickerText = NSMutableAttributedString(attributedString: DemoText.body("地球 "))
        stickerText.append(.persistentSticker(.earth, size: CGSize(width: 40, height: 40), alignTo: DemoText.bodyFont))
        stickerText.append(DemoText.body(" 与牛顿摆 "))
        stickerText.append(.persistentSticker(.cradle, size: CGSize(width: 40, height: 40), alignTo: DemoText.bodyFont))
        stickerText.append(DemoText.body(" 在静态文本位图上独立播放。"))
        stickerLabel.textLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 300), text: stickerText
        )
        stack.addArrangedSubview(stickerLabel)

        // Card 5 — text selection in .word mode (the expandable card
        // above demonstrates .all).
        stack.addArrangedSubview(header("文本选择：长按选词（.word）、拖手柄、菜单复制"))
        let selectionLabel = LoomLabel()
        let selectionText = DemoText.body(
            "长按任意词开始选择：今天天气真好 CJK 按词切分，emoji 👨‍👩‍👧‍👦 不会被劈开，"
                + "English words select whole. 拖动手柄调整选区，菜单里拷贝验证剪贴板。"
        )
        selectionLabel.textLayout = LoomTextLayout(
            containerSize: CGSize(width: width, height: 300), text: selectionText
        )
        selectionLabel.isTextSelectionEnabled = true
        selectionLabel.selectionInitialRange = .word
        stack.addArrangedSubview(selectionLabel)

        // Card 5.5 — middle truncation, file-path style: head…tail of
        // the full text on a single line.
        stack.addArrangedSubview(header("Middle 截断：路径省略（head…tail），长按选择复制不含洞"))
        let pathLabel = LoomLabel()
        pathLabel.isTextSelectionEnabled = true
        pathLabel.textLayout = LoomTextLayout(
            container: LoomTextContainer(
                size: CGSize(width: width, height: 40),
                maximumNumberOfRows: 1,
                truncationType: .middle
            ),
            text: DemoText.body(
                "/Users/yelo/Projects/LoomText/Sources/LoomText/LoomTextLayout+Drawing.swift"
            )
        )
        stack.addArrangedSubview(pathLabel)

        // Card 6 — toggles.
        stack.addArrangedSubview(header("渲染开关"))
        stack.addArrangedSubview(toggleRow(title: "异步绘制（displaysAsynchronously）", isOn: true) {
            [weak self] isOn in
            self?.allLoomLabels.forEach { $0.displaysAsynchronously = isOn }
        })
        stack.addArrangedSubview(toggleRow(title: "深色模式（动态色重绘）", isOn: false) { [weak self] isOn in
            self?.view.window?.overrideUserInterfaceStyle = isOn ? .dark : .light
        })
    }

    // MARK: - Actions

    private func toggleExpanded() {
        isExpanded.toggle()
        expandableLabel.textLayout = isExpanded ? expandedLayout : collapsedLayout
    }

    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private var allLoomLabels: [LoomLabel] {
        stack.arrangedSubviews.compactMap { $0 as? LoomLabel }
    }

    private func header(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func toggleRow(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.text = title
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { action in
            onChange((action.sender as? UISwitch)?.isOn ?? false)
        }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.distribution = .equalSpacing
        return row
    }

    private static func solidImage(color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
            _ = context
        }
    }
}
