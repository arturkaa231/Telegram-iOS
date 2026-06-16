import Foundation
import UIKit

final class MediaBrowserToggleView: UIControl {
    private let trackView = UIView()
    private let thumbView = UIView()

    private(set) var isOn: Bool = false

    var trackColorOn: UIColor = .systemGreen {
        didSet { self.updateColors() }
    }
    var trackColorOff: UIColor = .systemGray4 {
        didSet { self.updateColors() }
    }
    var thumbColor: UIColor = UIColor(red: 0x05/255.0, green: 0x61/255.0, blue: 0x4C/255.0, alpha: 1.0) {
        didSet { self.thumbView.backgroundColor = thumbColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame.isEmpty ? CGRect(origin: .zero, size: CGSize(width: 51.0, height: 31.0)) : frame)
        self.trackView.isUserInteractionEnabled = false
        self.thumbView.isUserInteractionEnabled = false
        self.thumbView.backgroundColor = self.thumbColor
        self.addSubview(self.trackView)
        self.addSubview(self.thumbView)
        self.isAccessibilityElement = true
        self.accessibilityTraits = [.button]
        self.accessibilityLabel = "Пульт"
        self.accessibilityValue = "Выключен"
        self.updateColors()
        self.setNeedsLayout()
        self.addTarget(self, action: #selector(self.tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: 51.0, height: 31.0)
    }

    func setOn(_ value: Bool, animated: Bool) {
        guard self.isOn != value else { return }
        self.isOn = value
        self.accessibilityValue = value ? "Включён" : "Выключен"
        let apply = {
            self.layoutThumb()
            self.updateColors()
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut], animations: apply)
        } else {
            apply()
        }
    }

    @objc private func tapped() {
        self.setOn(!self.isOn, animated: true)
        self.sendActions(for: .valueChanged)
    }

    private func updateColors() {
        self.trackView.backgroundColor = self.isOn ? self.trackColorOn : self.trackColorOff
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.trackView.frame = self.bounds
        self.trackView.layer.cornerRadius = self.bounds.height / 2.0
        self.layoutThumb()
    }

    private func layoutThumb() {
        let thumbSize: CGFloat = 24.0
        let inset: CGFloat = (self.bounds.height - thumbSize) / 2.0
        let x: CGFloat = self.isOn ? (self.bounds.width - inset - thumbSize) : inset
        self.thumbView.frame = CGRect(x: x, y: inset, width: thumbSize, height: thumbSize)
        self.thumbView.layer.cornerRadius = thumbSize / 2.0
    }
}
