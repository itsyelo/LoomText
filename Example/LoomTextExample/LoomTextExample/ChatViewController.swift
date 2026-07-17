//
//  ChatViewController.swift
//  LoomTextExample
//
//  10 000 messages with inline animated stickers. View models are pure
//  values built on a background queue (sticker descriptors, not views);
//  animated views come from StickerViewPool at mount time and go back
//  on unmount — the pool HUD shows live counts staying O(visible).
//
//  Deliberately flavor B only: persistent (flavor A) stickers hold one
//  view per attachment for their whole lifetime, which is exactly what
//  an unbounded list must avoid — see Showcase for flavor A.
//

import Loom
import LoomText
import SDWebImage
import UIKit

// MARK: - Avatars

private enum Avatar {
    static let me = URL(string: "https://randomuser.me/api/portraits/women/44.jpg")!
    static let others = [
        URL(string: "https://randomuser.me/api/portraits/men/32.jpg")!,
        URL(string: "https://randomuser.me/api/portraits/women/65.jpg")!,
        URL(string: "https://randomuser.me/api/portraits/men/75.jpg")!,
    ]

    static func url(id: Int, isOutgoing: Bool) -> URL {
        isOutgoing ? me : others[id % others.count]
    }
}

// MARK: - Layout keys & view model

private enum ChatKey: String, LoomKey {
    case avatar, bubble, text
    var loomKeyValue: String { rawValue }
}

private struct MessageVM {
    let id: Int
    let isOutgoing: Bool
    let avatarURL: URL
    let textLayout: LoomTextLayout
    let result: LayoutResult
    var height: CGFloat { result.height }

    @Sendable static func build(id: Int, width: CGFloat) -> MessageVM? {
        let isOutgoing = id % 3 == 2
        let bodyFont = UIFont.systemFont(ofSize: 16)
        let textColor: UIColor = isOutgoing ? .white : .label

        let phrases = [
            "这条消息带一个动态表情",
            "Animated stickers ride as view attachments — the text bitmap stays static",
            "复用池让活跃 view 数只跟屏幕可见数相关",
            "第 \(id) 条：万级消息的后台管线示例",
            "Frame buffers are shared per sticker via SDWebImage's cache",
        ]
        let text = NSMutableAttributedString(
            string: phrases[id % phrases.count] + " ",
            attributes: [.font: bodyFont, .foregroundColor: textColor]
        )
        // Two of every three messages carry an inline animated sticker
        // (flavor B: pool-backed descriptor, built safely off-main).
        if id % 3 != 1 {
            let sticker = Sticker.allCases[id % Sticker.allCases.count]
            text.append(.pooledSticker(sticker, size: CGSize(width: 32, height: 32), alignTo: bodyFont))
        }
        if id % 5 == 0 {
            text.append(NSAttributedString(
                string: " 补一句结尾让部分气泡换行，验证多行气泡的高度。",
                attributes: [.font: bodyFont, .foregroundColor: textColor]
            ))
        }

        let bubbleMaxWidth = width * 0.68
        guard let textLayout = LoomTextLayout(
            containerSize: CGSize(width: bubbleMaxWidth, height: 10_000), text: text
        ) else { return nil }

        let bubble = VStack {
            LTText(textLayout).key(ChatKey.text)
        }.padding(10).key(ChatKey.bubble)

        let row = LoomLayout(width: width) {
            if isOutgoing {
                HStack(spacing: 8, justify: .end, align: .start) {
                    bubble
                    Fixed(width: 36, height: 36).key(ChatKey.avatar)
                }.padding(12)
            } else {
                HStack(spacing: 8, align: .start) {
                    Fixed(width: 36, height: 36).key(ChatKey.avatar)
                    bubble
                }.padding(12)
            }
        }
        return MessageVM(
            id: id, isOutgoing: isOutgoing,
            avatarURL: Avatar.url(id: id, isOutgoing: isOutgoing),
            textLayout: textLayout, result: row.calculate()
        )
    }
}

// MARK: - Cell

private final class ChatBubbleCell: UITableViewCell {
    static let reuseID = "ChatBubbleCell"

    private let avatar = UIImageView()
    private let bubble = UIView()
    private let body = LoomLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        avatar.layer.cornerRadius = 18
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        bubble.layer.cornerRadius = 14
        contentView.addSubview(avatar)
        contentView.addSubview(bubble)
        contentView.addSubview(body)

        // WeChat-style bubble selection: long-press selects the whole
        // message, handles shrink it, the menu carries a host-injected
        // "转发" next to the system Copy.
        body.isTextSelectionEnabled = true
        body.additionalEditMenuItems = { [weak body] range in
            [UIAction(title: "转发") { _ in
                guard let body, let layout = body.textLayout else { return }
                let text = layout.plainText(in: range)
                body.clearSelection()
                let alert = UIAlertController(title: "转发", message: text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                body.window?.rootViewController?.present(alert, animated: true)
            }]
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(with vm: MessageVM) {
        avatar.backgroundColor = vm.isOutgoing ? .systemTeal : .systemIndigo // placeholder while loading / offline
        avatar.sd_setImage(with: vm.avatarURL)
        bubble.backgroundColor = vm.isOutgoing ? .systemBlue : .secondarySystemFill
        // Selection chrome (tint + handles) follows tintColor — the
        // default blue would vanish on the blue outgoing bubble.
        body.tintColor = vm.isOutgoing ? .white : .systemBlue
        body.textLayout = vm.textLayout
        avatar.frame = vm.result.frame(for: ChatKey.avatar) ?? .zero
        bubble.frame = vm.result.frame(for: ChatKey.bubble) ?? .zero
        body.frame = vm.result.frame(for: ChatKey.text) ?? .zero
    }
}

// MARK: - Controller

private final class InsetLabel: UILabel {
    var contentInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView()
    private let fpsView = FPSView()
    private let poolStats = InsetLabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var messages: [MessageVM] = []
    private var statsTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "聊天（10000 条 + 动态表情）"
        view.backgroundColor = .systemBackground

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.register(ChatBubbleCell.self, forCellReuseIdentifier: ChatBubbleCell.reuseID)
        view.addSubview(tableView)

        fpsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsView)

        poolStats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        poolStats.textColor = .white
        poolStats.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        poolStats.textAlignment = .center
        poolStats.layer.cornerRadius = 6
        poolStats.layer.masksToBounds = true
        poolStats.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(poolStats)

        NSLayoutConstraint.activate([
            poolStats.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            poolStats.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            fpsView.topAnchor.constraint(equalTo: poolStats.bottomAnchor, constant: 6),
            fpsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])

        spinner.center = view.center
        spinner.startAnimating()
        view.addSubview(spinner)

        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poolStats.text = StickerViewPool.shared.statsDescription
            }
        }

        startPipeline(width: UIScreen.main.bounds.width)
    }

    deinit { statsTimer?.invalidate() }

    private func startPipeline(width: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let total = 10_000
            let chunkSize = 500
            for chunkStart in stride(from: 0, to: total, by: chunkSize) {
                let chunk = (chunkStart..<min(chunkStart + chunkSize, total)).compactMap {
                    MessageVM.build(id: $0, width: width)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let start = self.messages.count
                    self.messages.append(contentsOf: chunk)
                    if start == 0 {
                        self.spinner.stopAnimating()
                        self.tableView.reloadData()
                    } else {
                        // Later chunks land below the fold; reloadData would
                        // re-render every visible bubble per chunk (async
                        // clear-then-redraw + sticker remount = strobing).
                        let paths = (start..<self.messages.count).map {
                            IndexPath(row: $0, section: 0)
                        }
                        UIView.performWithoutAnimation {
                            self.tableView.insertRows(at: paths, with: .none)
                        }
                    }
                    self.navigationItem.title = "聊天（\(self.messages.count) 条 + 动态表情）"
                }
            }
        }
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatBubbleCell.reuseID, for: indexPath
        ) as! ChatBubbleCell
        cell.configure(with: messages[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        messages[indexPath.row].height
    }
}
