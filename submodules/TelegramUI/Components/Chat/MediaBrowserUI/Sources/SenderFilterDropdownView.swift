import Foundation
import UIKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import AvatarNode

struct SenderInfo {
    let peerId: EnginePeer.Id
    let name: String
    let username: String?
    let peer: EnginePeer?
}

final class SenderFilterDropdownView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let tableView: UITableView
    private var allSenders: [SenderInfo] = []
    private var filteredSenders: [SenderInfo] = []
    private var currentFilter: String = ""

    var onSelect: ((SenderInfo) -> Void)?

    init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData
        self.tableView = UITableView(frame: .zero, style: .plain)
        super.init(frame: .zero)

        self.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        self.layer.cornerRadius = 20.0
        self.clipsToBounds = true

        self.tableView.backgroundColor = .clear
        self.tableView.separatorStyle = .none
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.register(SenderRowCell.self, forCellReuseIdentifier: "row")
        self.tableView.rowHeight = 44.0
        self.tableView.showsVerticalScrollIndicator = false
        self.tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        self.addSubview(self.tableView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.tableView.frame = self.bounds
    }

    func setSenders(_ senders: [SenderInfo]) {
        self.allSenders = senders
        self.applyFilter(self.currentFilter)
    }

    func applyFilter(_ text: String) {
        self.currentFilter = text
        let lower = text.lowercased()
        if lower.isEmpty {
            self.filteredSenders = self.allSenders
        } else {
            self.filteredSenders = self.allSenders.filter { sender in
                if sender.name.lowercased().contains(lower) { return true }
                if let un = sender.username?.lowercased(), un.contains(lower) { return true }
                return false
            }
        }
        self.tableView.reloadData()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.tableView.reloadData()
    }

    func contentHeight(maxHeight: CGFloat) -> CGFloat {
        let rowHeight: CGFloat = 44.0
        let verticalInset: CGFloat = 16.0
        let needed = CGFloat(self.filteredSenders.count) * rowHeight + verticalInset
        return max(0, min(needed, maxHeight))
    }

    var hasResults: Bool {
        return !self.filteredSenders.isEmpty
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.filteredSenders.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! SenderRowCell
        let sender = self.filteredSenders[indexPath.row]
        cell.configure(with: sender, context: self.context, theme: self.presentationData.theme)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < self.filteredSenders.count else { return }
        self.onSelect?(self.filteredSenders[indexPath.row])
    }
}

private final class SenderRowCell: UITableViewCell {
    private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 11.0))
    private let nameLabel = UILabel()
    private let usernameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.selectionStyle = .default

        self.nameLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        self.nameLabel.textColor = .white
        self.nameLabel.lineBreakMode = .byTruncatingTail

        self.usernameLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        self.usernameLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        self.usernameLabel.lineBreakMode = .byTruncatingTail

        contentView.addSubview(self.avatarNode.view)
        contentView.addSubview(self.nameLabel)
        contentView.addSubview(self.usernameLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentView.bounds.height
        let w = contentView.bounds.width
        let avatarSize: CGFloat = 24.0
        let leftPadding: CGFloat = 16.0
        let rightPadding: CGFloat = 16.0
        self.avatarNode.view.frame = CGRect(x: leftPadding, y: (h - avatarSize) / 2.0, width: avatarSize, height: avatarSize)
        self.avatarNode.updateSize(size: CGSize(width: avatarSize, height: avatarSize))

        let nameLeft = self.avatarNode.view.frame.maxX + 12.0
        let nameSize = (self.nameLabel.text ?? "").size(withAttributes: [.font: self.nameLabel.font as Any])
        let nameWidth = ceil(nameSize.width)
        let availableForName = max(40.0, w - rightPadding - nameLeft - 60.0)
        let clampedNameWidth = min(nameWidth, availableForName)
        self.nameLabel.frame = CGRect(x: nameLeft, y: 0, width: clampedNameWidth, height: h)

        let usernameLeft = nameLeft + clampedNameWidth + 6.0
        let usernameRight = w - rightPadding
        self.usernameLabel.frame = CGRect(x: usernameLeft, y: 0, width: max(0, usernameRight - usernameLeft), height: h)
    }

    func configure(with sender: SenderInfo, context: AccountContext, theme: PresentationTheme) {
        self.nameLabel.text = sender.name
        if let username = sender.username {
            self.usernameLabel.text = "@\(username)"
            self.usernameLabel.isHidden = false
        } else {
            self.usernameLabel.text = nil
            self.usernameLabel.isHidden = true
        }
        if let peer = sender.peer {
            self.avatarNode.setPeer(context: context, theme: theme, peer: peer, displayDimensions: CGSize(width: 24.0, height: 24.0))
            self.avatarNode.isHidden = false
        } else {
            self.avatarNode.isHidden = true
        }
        self.setNeedsLayout()
    }
}
