import Foundation
import UIKit

final class GradientView: UIView {
    override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }

    private var gradientLayer: CAGradientLayer {
        return self.layer as! CAGradientLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        self.gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        self.gradientLayer.locations = [0.0, 1.0]
        self.isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColors(_ colors: [UIColor]) {
        self.gradientLayer.colors = colors.map { $0.cgColor }
    }

    func setPoints(start: CGPoint, end: CGPoint) {
        self.gradientLayer.startPoint = start
        self.gradientLayer.endPoint = end
    }
}
