import SwiftUI

/// High-performance chart using SwiftUI Canvas (Core Graphics context).
/// ~10x cheaper than Apple Charts for live updating line graphs.
struct CanvasLineChart: View {
    let data: [Double]
    let color: Color
    let fillColor: Color?
    let lineWidth: CGFloat
    let yRange: ClosedRange<Double>?

    init(data: [Double], color: Color = .blue, fillColor: Color? = nil, lineWidth: CGFloat = 1.5, yRange: ClosedRange<Double>? = nil) {
        self.data = data
        self.color = color
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.yRange = yRange
    }

    var body: some View {
        Canvas { context, size in
            guard data.count >= 2 else { return }

            let minVal = yRange?.lowerBound ?? (data.min() ?? 0)
            let maxVal = yRange?.upperBound ?? (data.max() ?? 100)
            let range = max(maxVal - minVal, 1)

            let stepX = size.width / CGFloat(data.count - 1)

            var path = Path()
            for (i, value) in data.enumerated() {
                let x = CGFloat(i) * stepX
                let normalized = (value - minVal) / range
                let y = size.height - CGFloat(normalized) * size.height

                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Fill area under the line
            if let fillColor {
                var fillPath = path
                fillPath.addLine(to: CGPoint(x: CGFloat(data.count - 1) * stepX, y: size.height))
                fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                fillPath.closeSubpath()
                context.fill(fillPath, with: .color(fillColor))
            }

            // Stroke the line
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }
}

/// Multi-series line chart using Canvas
struct CanvasMultiLineChart: View {
    struct Series {
        let data: [Double]
        let color: Color
        let dashed: Bool

        init(data: [Double], color: Color, dashed: Bool = false) {
            self.data = data
            self.color = color
            self.dashed = dashed
        }
    }

    let series: [Series]
    let yRange: ClosedRange<Double>?

    init(series: [Series], yRange: ClosedRange<Double>? = nil) {
        self.series = series
        self.yRange = yRange
    }

    var body: some View {
        Canvas { context, size in
            guard let maxCount = series.map(\.data.count).max(), maxCount >= 2 else { return }

            let allValues = series.flatMap(\.data)
            let minVal = yRange?.lowerBound ?? (allValues.min() ?? 0)
            let maxVal = yRange?.upperBound ?? (allValues.max() ?? 100)
            let range = max(maxVal - minVal, 1)

            for s in series {
                guard s.data.count >= 2 else { continue }

                let stepX = size.width / CGFloat(s.data.count - 1)
                var path = Path()

                for (i, value) in s.data.enumerated() {
                    let x = CGFloat(i) * stepX
                    let normalized = (value - minVal) / range
                    let y = size.height - CGFloat(normalized) * size.height

                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }

                let style: StrokeStyle
                if s.dashed {
                    style = StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                } else {
                    style = StrokeStyle(lineWidth: 1.5)
                }

                context.stroke(path, with: .color(s.color), style: style)
            }
        }
    }
}

/// Gauge view using Canvas
struct CanvasGauge: View {
    let percent: Double
    let color: Color
    let lineWidth: CGFloat

    init(percent: Double, color: Color, lineWidth: CGFloat = 6) {
        self.percent = percent
        self.color = color
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - lineWidth / 2

            // Background circle
            var bgPath = Path()
            bgPath.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            context.stroke(bgPath, with: .color(.secondary.opacity(0.15)), lineWidth: lineWidth)

            // Value arc
            let endAngle = 360 * min(percent / 100, 1)
            var valuePath = Path()
            valuePath.addArc(center: center, radius: radius,
                           startAngle: .degrees(-90), endAngle: .degrees(-90 + endAngle), clockwise: false)
            context.stroke(valuePath, with: .color(color),
                         style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}
