//
//  PerfViewController.swift
//  LoomTextExample
//
//  UILabel vs LoomLabel on identical data with an FPS HUD. LoomLabel
//  rows use precomputed layouts (direct mode, async rendering); UILabel
//  rows typeset on the main thread during scroll, as usual.
//

import LoomText
import UIKit

final class PerfViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private enum Mode: Int { case uiLabel = 0, loomLabel }

    private let tableView = UITableView()
    private let fpsView = FPSView()
    private let segmented = UISegmentedControl(items: ["UILabel", "LoomLabel"])
    private var mode: Mode = .uiLabel

    private var texts: [NSAttributedString] = []
    private var layouts: [LoomTextLayout] = []
    /// Per-engine heights: each mode sizes rows with its own engine —
    /// TextKit drifts ~0.5pt/line from CoreText on mixed-script text, so
    /// sharing one measurement would clip the other engine's last line.
    private var loomHeights: [CGFloat] = []
    private var uiKitHeights: [CGFloat] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "滚动性能对比"
        view.backgroundColor = .systemBackground

        segmented.selectedSegmentIndex = 0
        segmented.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.mode = Mode(rawValue: self.segmented.selectedSegmentIndex) ?? .uiLabel
            self.tableView.reloadData()
        }, for: .valueChanged)
        navigationItem.titleView = segmented

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UILabelCell.self, forCellReuseIdentifier: UILabelCell.reuseID)
        tableView.register(LoomCell.self, forCellReuseIdentifier: LoomCell.reuseID)
        view.addSubview(tableView)

        fpsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsView)
        NSLayoutConstraint.activate([
            fpsView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            fpsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])

        buildData(width: UIScreen.main.bounds.width - 32)
    }

    /// Realistic feed bodies: variable length (2–12 lines), multiple
    /// attribute runs (bold title, colored mentions, secondary meta),
    /// line spacing, and CJK/Latin/emoji mixing — the shaping load where
    /// main-thread typesetting actually costs. Deterministic per index
    /// so both modes render identical strings.
    private func buildData(width: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fragments = [
                "后台排版一次，测量与渲染共用同一份数据，主线程只剩位图提交。",
                "The quick brown fox jumps over the lazy dog while 敏捷的棕色狐狸跳过懒狗 🦊🐕。",
                "多属性 run 会显著增加 shaping 成本：粗体、彩色、字体回退与 emoji 序列 👨‍👩‍👧‍👦 混在一起。",
                "Variable-length paragraphs are what separate a real feed from a synthetic benchmark, ",
                "长文折叠、@提及 高亮、行距调整 — every attribute adds a run boundary. ",
                "滚动的每一帧里，UILabel 都要重新排版；LoomLabel 只是把预先算好的位图贴上去 🎉。",
            ]
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4

            var texts: [NSAttributedString] = []
            var layouts: [LoomTextLayout] = []
            var loomHeights: [CGFloat] = []
            var uiKitHeights: [CGFloat] = []
            for index in 0..<500 {
                let text = NSMutableAttributedString(
                    string: "用户动态 #\(index) · Loom 性能样本\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 16, weight: .bold),
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: style,
                    ]
                )
                // 2–12 body lines, varying per row to defeat caching and
                // exercise realistic height diversity.
                let sentenceCount = 2 + (index * 7) % 11
                for offset in 0..<sentenceCount {
                    let fragment = fragments[(index + offset) % fragments.count]
                    text.append(NSAttributedString(string: fragment, attributes: [
                        .font: DemoText.bodyFont,
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: style,
                    ]))
                }
                if index % 3 == 0 {
                    text.append(NSAttributedString(string: " @Yelo", attributes: [
                        .font: DemoText.bodyFont,
                        .foregroundColor: UIColor.systemBlue,
                        .paragraphStyle: style,
                    ]))
                }
                text.append(NSAttributedString(string: "\n5 分钟前 · 来自 LoomText Example", attributes: [
                    .font: UIFont.systemFont(ofSize: 13),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: style,
                ]))

                guard let layout = LoomTextLayout(
                    containerSize: CGSize(width: width, height: 10_000), text: text
                ) else { continue }
                texts.append(text)
                layouts.append(layout)
                loomHeights.append(layout.textBoundingSize.height + 24)
                let uiKitSize = text.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                uiKitHeights.append(ceil(uiKitSize.height) + 24)
            }
            DispatchQueue.main.async {
                self?.texts = texts
                self?.layouts = layouts
                self?.loomHeights = loomHeights
                self?.uiKitHeights = uiKitHeights
                self?.tableView.reloadData()
            }
        }
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        layouts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch mode {
        case .uiLabel:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: UILabelCell.reuseID, for: indexPath
            ) as! UILabelCell
            cell.label.attributedText = texts[indexPath.row]
            return cell
        case .loomLabel:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: LoomCell.reuseID, for: indexPath
            ) as! LoomCell
            cell.label.textLayout = layouts[indexPath.row]
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch mode {
        case .uiLabel: return uiKitHeights[indexPath.row]
        case .loomLabel: return loomHeights[indexPath.row]
        }
    }
}

// MARK: - Cells

private final class UILabelCell: UITableViewCell {
    static let reuseID = "UILabelCell"
    let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        label.numberOfLines = 0
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 16, dy: 12)
    }
}

private final class LoomCell: UITableViewCell {
    static let reuseID = "LoomCell"
    let label = LoomLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 16, dy: 12)
    }
}

// FPS HUD moved to FPSView.swift (shared with the Chat tab).
