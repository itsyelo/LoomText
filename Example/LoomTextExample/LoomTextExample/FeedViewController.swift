//
//  FeedViewController.swift
//  LoomTextExample
//
//  The Loom pipeline paradigm with LoomText rendering: view models are
//  built on a background queue — attributed strings, both collapsed and
//  expanded LoomTextLayouts, and both Loom LayoutResults — and published
//  to the main thread in chunks. Cells assign precomputed frames and
//  layouts; scrolling and expand/collapse perform zero typesetting.
//

import Loom
import LoomText
import UIKit

// MARK: - Keys & view model

private enum CellKey: String, LoomKey {
    case avatar, name, body
    var loomKeyValue: String { rawValue }
}

private struct PostVM {
    let id: Int
    let nameLayout: LoomTextLayout
    let collapsedBody: LoomTextLayout
    let expandedBody: LoomTextLayout
    let collapsedResult: LayoutResult
    let expandedResult: LayoutResult
    var isExpanded = false

    var bodyLayout: LoomTextLayout { isExpanded ? expandedBody : collapsedBody }
    var result: LayoutResult { isExpanded ? expandedResult : collapsedResult }

    @Sendable static func build(id: Int, width: CGFloat) -> PostVM? {
        let name = NSAttributedString(string: "Loom 用户 \(id)", attributes: [
            .font: DemoText.nameFont, .foregroundColor: UIColor.label,
        ])
        let body = DemoText.body(
            "第 \(id) 条内容：@Yelo 的 feed 管线示例。后台一次性排版折叠与展开两套布局，"
                + "cell 上屏与展开收起都不做任何计算。LoomText renders this body off the "
                + "main thread with sentinel cancellation, and the collapsed prefix matches "
                + "the expanded layout pixel for pixel. 中英文混排与 emoji 🎉 一并覆盖。",
            mention: "@Yelo"
        )

        let textWidth = width - 16 * 2 - 40 - 12
        guard
            let nameLayout = LoomTextLayout(
                containerSize: CGSize(width: textWidth, height: 40), text: name
            ),
            let collapsed = LoomTextLayout(
                container: LoomTextContainer(
                    size: CGSize(width: textWidth, height: 10_000),
                    maximumNumberOfRows: 3,
                    truncationToken: DemoText.expandToken()
                ),
                text: body
            ),
            let expanded = LoomTextLayout(
                containerSize: CGSize(width: textWidth, height: 10_000), text: body
            )
        else { return nil }

        func tree(_ bodyLayout: LoomTextLayout) -> LoomLayout {
            LoomLayout(width: width) {
                HStack(spacing: 12) {
                    Fixed(width: 40, height: 40).key(CellKey.avatar)
                    VStack(spacing: 6) {
                        LTText(nameLayout).key(CellKey.name)
                        LTText(bodyLayout).key(CellKey.body)
                    }.flex(grow: 1)
                }.padding(16)
            }
        }

        return PostVM(
            id: id,
            nameLayout: nameLayout,
            collapsedBody: collapsed,
            expandedBody: expanded,
            collapsedResult: tree(collapsed).calculate(),
            expandedResult: tree(expanded).calculate()
        )
    }
}

// MARK: - Cell

private final class FeedCell: UITableViewCell {
    static let reuseID = "FeedCell"

    let avatar = UIView()
    let name = LoomLabel()
    let body = LoomLabel()
    var onToggle: (() -> Void)?
    var onMention: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        avatar.backgroundColor = .systemIndigo
        avatar.layer.cornerRadius = 20
        contentView.addSubview(avatar)
        contentView.addSubview(name)
        contentView.addSubview(body)
        // Route on the tapped highlight's payload — token taps expand,
        // mention taps surface the mention.
        body.highlightTapAction = { [weak self] _, text, range, _ in
            guard text.length > 0 else { return }
            let index = min(range.location, text.length - 1)
            let highlight = text.attribute(.loomTextHighlight, at: index, effectiveRange: nil)
                as? LoomTextHighlight
            switch highlight?.userInfo?["action"] as? String {
            case "expand":
                self?.onToggle?()
            case "mention":
                self?.onMention?(highlight?.userInfo?["name"] as? String ?? "")
            default:
                break
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(with vm: PostVM) {
        name.textLayout = vm.nameLayout
        body.textLayout = vm.bodyLayout
        avatar.frame = vm.result.frame(for: CellKey.avatar) ?? .zero
        name.frame = vm.result.frame(for: CellKey.name) ?? .zero
        body.frame = vm.result.frame(for: CellKey.body) ?? .zero
    }
}

// MARK: - Controller

final class FeedViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView()
    private var posts: [PostVM] = []
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Loom Feed（后台管线）"
        view.backgroundColor = .systemBackground

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorInset = .zero
        tableView.register(FeedCell.self, forCellReuseIdentifier: FeedCell.reuseID)
        view.addSubview(tableView)

        spinner.center = view.center
        spinner.startAnimating()
        view.addSubview(spinner)

        startPipeline(width: UIScreen.main.bounds.width)
    }

    /// Background build → chunked main-thread publish (the Loom feed
    /// pipeline pattern).
    private func startPipeline(width: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let chunkSize = 50
            for chunkStart in stride(from: 0, to: 300, by: chunkSize) {
                let chunk = (chunkStart..<chunkStart + chunkSize).compactMap {
                    PostVM.build(id: $0, width: width)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner.stopAnimating()
                    self.posts.append(contentsOf: chunk)
                    self.tableView.reloadData()
                }
            }
        }
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        posts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FeedCell.reuseID, for: indexPath
        ) as! FeedCell
        cell.configure(with: posts[indexPath.row])
        cell.onToggle = { [weak self] in
            guard let self else { return }
            self.posts[indexPath.row].isExpanded.toggle()
            self.tableView.reloadRows(at: [indexPath], with: .fade)
        }
        cell.onMention = { [weak self] name in
            let alert = UIAlertController(title: "Tapped \(name)", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        posts[indexPath.row].result.height
    }
}
