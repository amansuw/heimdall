import AppKit
import QuartzCore

/// Pure AppKit + Core Animation menu bar widget.
/// Uses CALayers for GPU-accelerated rendering with zero SwiftUI overhead.
class MenuBarWidgetView: NSView {
    private let fanIconLayer = CALayer()
    private let tempTextLayer = CATextLayer()

    private var currentRotation: CGFloat = 0
    private var fanImage: NSImage?
    private var isLoading = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Fan icon layer
        fanIconLayer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        fanIconLayer.position = CGPoint(x: 14, y: 11)
        fanIconLayer.contentsGravity = .resizeAspect

        // Create fan icon from SF Symbol
        if let img = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "Fan") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            fanImage = img.withSymbolConfiguration(config)
            updateFanIconImage(color: .systemGray)
        }

        layer?.addSublayer(fanIconLayer)
    }

    func updateFanIcon(color: NSColor, rotation: CGFloat) {
        guard !isLoading else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        updateFanIconImage(color: color)

        // Static rotation angle based on fan speed — no animation loop
        fanIconLayer.transform = CATransform3DMakeRotation(rotation * .pi / 180, 0, 0, 1)

        CATransaction.commit()
    }

    func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if loading {
            updateFanIconImage(color: .systemBlue)
            fanIconLayer.transform = CATransform3DIdentity

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 0.8
            spin.repeatCount = .infinity
            fanIconLayer.add(spin, forKey: "loading.spin")
        } else {
            fanIconLayer.removeAnimation(forKey: "loading.spin")
            fanIconLayer.transform = CATransform3DIdentity
        }

        CATransaction.commit()
    }

    func updateTempText(temp: Double) {
        // Temperature text is not shown by default to keep menu bar compact
        // Can be enabled via settings
    }

    private func updateFanIconImage(color: NSColor) {
        guard let baseImage = fanImage else { return }

        let size = NSSize(width: 16, height: 16)
        let coloredImage = NSImage(size: size, flipped: false) { rect in
            baseImage.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        fanIconLayer.contents = coloredImage
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 22)
    }
}
