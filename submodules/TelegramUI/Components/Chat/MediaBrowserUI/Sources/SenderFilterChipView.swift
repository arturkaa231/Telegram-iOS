import Foundation
import UIKit

final class SenderFilterChipView: UIView, UITextFieldDelegate {
    enum FilterState {
        case multi
        case searching
        case selected(name: String, username: String?)
    }

    private(set) var state: FilterState = .multi

    private let leftBgView = UIView()
    private let rightBgView = UIView()
    private let leftIconView = UIImageView()
    private let rightIconView = UIImageView()
    private let nameLabel = UILabel()
    private let atSymbolLabel = UILabel()
    private let searchTextField = UITextField()
    private let leftButton = UIButton(type: .custom)
    private let rightButton = UIButton(type: .custom)

    var onTapMulti: (() -> Void)?
    var onTapSingle: (() -> Void)?
    var onSearchTextChanged: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let cfg = UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)

        self.leftBgView.layer.cornerRadius = 22.0
        self.leftBgView.clipsToBounds = true
        self.leftBgView.isUserInteractionEnabled = false

        self.rightBgView.layer.cornerRadius = 22.0
        self.rightBgView.clipsToBounds = true
        self.rightBgView.isUserInteractionEnabled = false

        self.leftIconView.image = UIImage(systemName: "person.2.fill", withConfiguration: cfg)
        self.leftIconView.tintColor = .white
        self.leftIconView.contentMode = .center
        self.leftIconView.isUserInteractionEnabled = false

        self.rightIconView.image = UIImage(systemName: "person.fill", withConfiguration: cfg)
        self.rightIconView.tintColor = .white
        self.rightIconView.contentMode = .center
        self.rightIconView.isUserInteractionEnabled = false

        self.atSymbolLabel.text = "@"
        self.atSymbolLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        self.atSymbolLabel.textColor = .white
        self.atSymbolLabel.isHidden = true

        self.nameLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.nameLabel.textColor = .white
        self.nameLabel.lineBreakMode = .byTruncatingTail
        self.nameLabel.isHidden = true

        self.searchTextField.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        self.searchTextField.textColor = .white
        self.searchTextField.tintColor = .white
        self.searchTextField.autocorrectionType = .no
        self.searchTextField.autocapitalizationType = .none
        self.searchTextField.spellCheckingType = .no
        self.searchTextField.returnKeyType = .search
        self.searchTextField.delegate = self
        self.searchTextField.isHidden = true
        self.searchTextField.addTarget(self, action: #selector(self.textChanged), for: .editingChanged)

        self.leftButton.addTarget(self, action: #selector(self.leftTapped), for: .touchUpInside)
        self.rightButton.addTarget(self, action: #selector(self.rightTapped), for: .touchUpInside)

        self.addSubview(self.leftBgView)
        self.addSubview(self.rightBgView)
        self.addSubview(self.leftIconView)
        self.addSubview(self.rightIconView)
        self.addSubview(self.atSymbolLabel)
        self.addSubview(self.nameLabel)
        self.addSubview(self.searchTextField)
        self.addSubview(self.leftButton)
        self.addSubview(self.rightButton)

        self.applyStateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setState(_ state: FilterState) {
        self.state = state
        switch state {
        case .multi:
            self.atSymbolLabel.isHidden = true
            self.nameLabel.isHidden = true
            self.searchTextField.isHidden = true
            self.searchTextField.text = ""
            self.nameLabel.text = nil
        case .searching:
            self.atSymbolLabel.isHidden = false
            self.nameLabel.isHidden = true
            self.searchTextField.isHidden = false
            self.nameLabel.text = nil
        case let .selected(name, username):
            self.atSymbolLabel.isHidden = false
            self.nameLabel.isHidden = false
            self.searchTextField.isHidden = true
            self.searchTextField.text = ""
            if let username = username {
                self.nameLabel.text = "\(name) @\(username)"
            } else {
                self.nameLabel.text = name
            }
        }
        self.applyStateColors()
        self.invalidateIntrinsicContentSize()
        self.setNeedsLayout()
    }

    func activateSearch() {
        self.setState(.searching)
        self.searchTextField.becomeFirstResponder()
    }

    func deactivateSearch() {
        self.searchTextField.resignFirstResponder()
    }

    var searchText: String {
        return self.searchTextField.text ?? ""
    }

    @objc private func textChanged() {
        self.onSearchTextChanged?(self.searchText)
    }

    override var intrinsicContentSize: CGSize {
        switch self.state {
        case .multi:
            return CGSize(width: 96.0, height: 44.0)
        case .searching:
            return CGSize(width: 280.0, height: 44.0)
        case .selected:
            let textWidth = (self.nameLabel.text ?? "").size(withAttributes: [.font: self.nameLabel.font as Any]).width
            let total = 44.0 + 8.0 + 44.0 + 24.0 + ceil(textWidth) + 24.0
            return CGSize(width: total, height: 44.0)
        }
    }

    private func applyStateColors() {
        switch self.state {
        case .multi:
            self.leftBgView.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            self.rightBgView.backgroundColor = UIColor.clear
            self.leftIconView.alpha = 1.0
            self.rightIconView.alpha = 0.75
        case .searching, .selected:
            self.leftBgView.backgroundColor = UIColor.clear
            self.rightBgView.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            self.leftIconView.alpha = 0.75
            self.rightIconView.alpha = 1.0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = self.bounds.height
        let halfRadius = h / 2.0

        switch self.state {
        case .multi:
            let halfWidth = self.bounds.width / 2.0
            self.leftBgView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: h)
            self.leftBgView.layer.cornerRadius = halfRadius
            self.rightBgView.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: h)
            self.rightBgView.layer.cornerRadius = halfRadius
            self.leftIconView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: h)
            self.rightIconView.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: h)
            self.rightIconView.isHidden = false
            self.leftButton.frame = CGRect(x: 0, y: 0, width: halfWidth, height: h)
            self.rightButton.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: h)
            self.atSymbolLabel.frame = .zero
            self.nameLabel.frame = .zero
            self.searchTextField.frame = .zero
        case .searching:
            let iconWidth: CGFloat = 44.0
            self.leftBgView.frame = CGRect(x: 0, y: 0, width: iconWidth, height: h)
            self.leftBgView.layer.cornerRadius = halfRadius
            self.leftIconView.frame = CGRect(x: 0, y: 0, width: iconWidth, height: h)
            self.leftButton.frame = CGRect(x: 0, y: 0, width: iconWidth, height: h)

            let rightStartX = iconWidth + 4.0
            let rightWidth = self.bounds.width - rightStartX
            self.rightBgView.frame = CGRect(x: rightStartX, y: 0, width: rightWidth, height: h)
            self.rightBgView.layer.cornerRadius = halfRadius
            self.rightIconView.isHidden = true
            self.rightIconView.frame = .zero
            self.rightButton.frame = .zero

            let atX = rightStartX + 20.0
            self.atSymbolLabel.sizeToFit()
            self.atSymbolLabel.frame = CGRect(x: atX, y: (h - self.atSymbolLabel.frame.height) / 2.0, width: self.atSymbolLabel.frame.width, height: self.atSymbolLabel.frame.height)

            let textX = self.atSymbolLabel.frame.maxX + 4.0
            let textRight = rightStartX + rightWidth - 16.0
            self.searchTextField.frame = CGRect(x: textX, y: 0, width: max(40.0, textRight - textX), height: h)
            self.nameLabel.frame = .zero
        case .selected:
            let iconWidth: CGFloat = 44.0
            self.leftBgView.frame = CGRect(x: 0, y: 0, width: iconWidth, height: h)
            self.leftBgView.layer.cornerRadius = halfRadius
            self.leftIconView.frame = CGRect(x: 0, y: 0, width: iconWidth, height: h)
            self.leftButton.frame = CGRect(x: 0, y: 0, width: iconWidth, height: h)

            let rightStartX = iconWidth + 4.0
            let rightWidth = self.bounds.width - rightStartX
            self.rightBgView.frame = CGRect(x: rightStartX, y: 0, width: rightWidth, height: h)
            self.rightBgView.layer.cornerRadius = halfRadius
            self.rightIconView.isHidden = false
            self.rightIconView.frame = CGRect(x: rightStartX, y: 0, width: iconWidth, height: h)
            self.rightButton.frame = CGRect(x: rightStartX, y: 0, width: rightWidth, height: h)

            let textStart = rightStartX + iconWidth + 4.0
            self.atSymbolLabel.sizeToFit()
            self.atSymbolLabel.frame = CGRect(x: textStart, y: (h - self.atSymbolLabel.frame.height) / 2.0, width: self.atSymbolLabel.frame.width, height: self.atSymbolLabel.frame.height)
            let nameLeft = self.atSymbolLabel.frame.maxX + 6.0
            let nameRight = rightStartX + rightWidth - 16.0
            self.nameLabel.frame = CGRect(x: nameLeft, y: 0, width: max(40.0, nameRight - nameLeft), height: h)
            self.searchTextField.frame = .zero
        }
    }

    @objc private func leftTapped() {
        self.onTapMulti?()
    }

    @objc private func rightTapped() {
        self.onTapSingle?()
    }
}
