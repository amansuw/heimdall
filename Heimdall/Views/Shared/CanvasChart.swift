import SwiftUI

// MARK: - Chart Insets (room for axis labels)

private let chartLeftPad: CGFloat = 40
private let chartBottomPad: CGFloat = 20

// MARK: - Hover State

@Observable
class ChartHoverState {
    var hoverX: CGFloat? = nil
}

// MARK: - Axis Helpers

private func drawYAxis(
    _ context: GraphicsContext,
    size: CGSize,
    minVal: Double,
    maxVal: Double,
    steps: Int = 4,
    formatter: (Double) -> String = { String(format: "%.0f", $0) }
) {
    let range = maxVal - minVal
    guard range > 0 else { return }
    let plotH = size.height - chartBottomPad
    for i in 0...steps {
        let frac = Double(i) / Double(steps)
        let val = minVal + frac * range
        let y = plotH - frac * plotH
        // Grid line
        var gridPath = Path()
        gridPath.move(to: CGPoint(x: chartLeftPad, y: y))
        gridPath.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(gridPath, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        // Label
        var labelY = y
        if i == 0 { labelY -= 6 }
        else if i == steps { labelY += 6 }
        let label = Text(formatter(val)).font(.system(size: 9)).foregroundColor(.secondary)
        context.draw(context.resolve(label), at: CGPoint(x: chartLeftPad - 4, y: labelY), anchor: .trailing)
    }
}

private func drawXAxisIndices(
    _ context: GraphicsContext,
    size: CGSize,
    count: Int,
    tickCount: Int = 5,
    formatter: (Int) -> String = { "\($0)" }
) {
    guard count >= 2 else { return }
    let plotW = size.width - chartLeftPad
    let plotH = size.height - chartBottomPad
    for i in 0...tickCount {
        let frac = CGFloat(i) / CGFloat(tickCount)
        let x = chartLeftPad + frac * plotW
        let idx = Int(frac * CGFloat(count - 1))
        // Tick
        var tick = Path()
        tick.move(to: CGPoint(x: x, y: plotH))
        tick.addLine(to: CGPoint(x: x, y: plotH + 3))
        context.stroke(tick, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
        // Label
        let label = Text(formatter(idx)).font(.system(size: 8)).foregroundColor(.secondary)
        context.draw(context.resolve(label), at: CGPoint(x: x, y: plotH + 10), anchor: .center)
    }
}

// MARK: - Hover Overlay

private struct ChartHoverOverlay: View {
    let hoverState: ChartHoverState

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverState.hoverX = loc.x
                    case .ended:
                        hoverState.hoverX = nil
                    }
                }
        }
    }
}

// MARK: - Hover Tooltip

private struct ChartTooltip: View {
    let values: [(Color, String, String)]  // (color, label, value)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle().fill(item.0).frame(width: 6, height: 6)
                    Text(item.1).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(item.2).font(.system(size: 9, weight: .medium, design: .rounded))
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Single Line Chart

/// High-performance chart using SwiftUI Canvas (Core Graphics context).
/// ~10x cheaper than Apple Charts for live updating line graphs.
struct CanvasLineChart: View {
    let data: [Double]
    let color: Color
    let fillColor: Color?
    let lineWidth: CGFloat
    let yRange: ClosedRange<Double>?
    let label: String
    let yFormatter: (Double) -> String
    let tooltipFormatter: (Double) -> String

    @State private var hoverState = ChartHoverState()

    init(
        data: [Double],
        color: Color = .blue,
        fillColor: Color? = nil,
        lineWidth: CGFloat = 1.5,
        yRange: ClosedRange<Double>? = nil,
        label: String = "Value",
        yFormatter: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        tooltipFormatter: @escaping (Double) -> String = { String(format: "%.1f", $0) }
    ) {
        self.data = data
        self.color = color
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.yRange = yRange
        self.label = label
        self.yFormatter = yFormatter
        self.tooltipFormatter = tooltipFormatter
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                guard data.count >= 2 else { return }

                let minVal = yRange?.lowerBound ?? (data.min() ?? 0)
                let maxVal = yRange?.upperBound ?? (data.max() ?? 100)
                let range = max(maxVal - minVal, 1)
                let plotW = size.width - chartLeftPad
                let plotH = size.height - chartBottomPad

                drawYAxis(context, size: size, minVal: minVal, maxVal: maxVal, formatter: yFormatter)
                drawXAxisIndices(context, size: size, count: data.count)

                let stepX = plotW / CGFloat(data.count - 1)

                var path = Path()
                for (i, value) in data.enumerated() {
                    let x = chartLeftPad + CGFloat(i) * stepX
                    let normalized = (value - minVal) / range
                    let y = plotH - CGFloat(normalized) * plotH
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }

                if let fillColor {
                    var fillPath = path
                    fillPath.addLine(to: CGPoint(x: chartLeftPad + CGFloat(data.count - 1) * stepX, y: plotH))
                    fillPath.addLine(to: CGPoint(x: chartLeftPad, y: plotH))
                    fillPath.closeSubpath()
                    context.fill(fillPath, with: .color(fillColor))
                }

                context.stroke(path, with: .color(color), lineWidth: lineWidth)

                // Hover crosshair
                if let hx = hoverState.hoverX, hx >= chartLeftPad, hx <= size.width {
                    let relX = hx - chartLeftPad
                    let idx = Int(round(relX / stepX))
                    let clampedIdx = max(0, min(data.count - 1, idx))
                    let snapX = chartLeftPad + CGFloat(clampedIdx) * stepX
                    let val = data[clampedIdx]
                    let snapY = plotH - CGFloat((val - minVal) / range) * plotH

                    var vLine = Path()
                    vLine.move(to: CGPoint(x: snapX, y: 0))
                    vLine.addLine(to: CGPoint(x: snapX, y: plotH))
                    context.stroke(vLine, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    let dot = Path(ellipseIn: CGRect(x: snapX - 4, y: snapY - 4, width: 8, height: 8))
                    context.fill(dot, with: .color(color))
                    context.stroke(dot, with: .color(.white), lineWidth: 1.5)
                }
            }

            ChartHoverOverlay(hoverState: hoverState)

            // Tooltip
            if let hx = hoverState.hoverX, hx >= chartLeftPad, data.count >= 2 {
                let plotW = 1.0 // dummy to compute
                let _ = plotW
                tooltipView
            }
        }
    }

    @ViewBuilder
    private var tooltipView: some View {
        GeometryReader { geo in
            let plotW = geo.size.width - chartLeftPad
            let stepX = plotW / CGFloat(max(data.count - 1, 1))
            let relX = (hoverState.hoverX ?? 0) - chartLeftPad
            let idx = max(0, min(data.count - 1, Int(round(relX / stepX))))
            let val = data[idx]
            let xPos = chartLeftPad + CGFloat(idx) * stepX

            ChartTooltip(values: [(color, label, tooltipFormatter(val))])
                .fixedSize()
                .position(x: min(max(xPos, chartLeftPad + 40), geo.size.width - 40), y: 16)
        }
    }
}

// MARK: - Multi-Series Line Chart

/// Multi-series line chart using Canvas
struct CanvasMultiLineChart: View {
    struct Series {
        let data: [Double]
        let color: Color
        let label: String
        let dashed: Bool

        init(data: [Double], color: Color, label: String = "", dashed: Bool = false) {
            self.data = data
            self.color = color
            self.label = label
            self.dashed = dashed
        }
    }

    let series: [Series]
    let yRange: ClosedRange<Double>?
    let yFormatter: (Double) -> String
    let tooltipFormatter: (Double) -> String
    let xFormatter: (Int) -> String

    @State private var hoverState = ChartHoverState()

    init(
        series: [Series],
        yRange: ClosedRange<Double>? = nil,
        yFormatter: @escaping (Double) -> String = { String(format: "%.0f", $0) },
        tooltipFormatter: @escaping (Double) -> String = { String(format: "%.1f", $0) },
        xFormatter: @escaping (Int) -> String = { "\($0)" }
    ) {
        self.series = series
        self.yRange = yRange
        self.yFormatter = yFormatter
        self.tooltipFormatter = tooltipFormatter
        self.xFormatter = xFormatter
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                guard let maxCount = series.map(\.data.count).max(), maxCount >= 2 else { return }

                let allValues = series.flatMap(\.data)
                let minVal = yRange?.lowerBound ?? (allValues.min() ?? 0)
                let maxVal = yRange?.upperBound ?? (allValues.max() ?? 100)
                let range = max(maxVal - minVal, 1)
                let plotW = size.width - chartLeftPad
                let plotH = size.height - chartBottomPad

                drawYAxis(context, size: size, minVal: minVal, maxVal: maxVal, formatter: yFormatter)
                drawXAxisIndices(context, size: size, count: maxCount, formatter: xFormatter)

                for s in series {
                    guard s.data.count >= 2 else { continue }
                    let stepX = plotW / CGFloat(s.data.count - 1)
                    var path = Path()
                    for (i, value) in s.data.enumerated() {
                        let x = chartLeftPad + CGFloat(i) * stepX
                        let normalized = (value - minVal) / range
                        let y = plotH - CGFloat(normalized) * plotH
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    let style: StrokeStyle = s.dashed
                        ? StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        : StrokeStyle(lineWidth: 1.5)
                    context.stroke(path, with: .color(s.color), style: style)
                }

                // Hover crosshair
                if let hx = hoverState.hoverX, hx >= chartLeftPad, hx <= size.width {
                    let refCount = series.first?.data.count ?? maxCount
                    let stepX = plotW / CGFloat(max(refCount - 1, 1))
                    let relX = hx - chartLeftPad
                    let idx = max(0, min(refCount - 1, Int(round(relX / stepX))))
                    let snapX = chartLeftPad + CGFloat(idx) * stepX

                    var vLine = Path()
                    vLine.move(to: CGPoint(x: snapX, y: 0))
                    vLine.addLine(to: CGPoint(x: snapX, y: plotH))
                    context.stroke(vLine, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // Dots on each series
                    for s in series {
                        guard idx < s.data.count else { continue }
                        let val = s.data[idx]
                        let snapY = plotH - CGFloat((val - minVal) / range) * plotH
                        let dot = Path(ellipseIn: CGRect(x: snapX - 4, y: snapY - 4, width: 8, height: 8))
                        context.fill(dot, with: .color(s.color))
                        context.stroke(dot, with: .color(.white), lineWidth: 1.5)
                    }
                }
            }

            ChartHoverOverlay(hoverState: hoverState)

            // Tooltip
            if hoverState.hoverX != nil {
                multiTooltipView
            }
        }
    }

    @ViewBuilder
    private var multiTooltipView: some View {
        GeometryReader { geo in
            let maxCount = series.map(\.data.count).max() ?? 2
            let plotW = geo.size.width - chartLeftPad
            let stepX = plotW / CGFloat(max(maxCount - 1, 1))
            let relX = (hoverState.hoverX ?? 0) - chartLeftPad
            let idx = max(0, min(maxCount - 1, Int(round(relX / stepX))))
            let xPos = chartLeftPad + CGFloat(idx) * stepX

            let items: [(Color, String, String)] = series.compactMap { s in
                guard idx < s.data.count else { return nil }
                let lbl = s.label.isEmpty ? "Series" : s.label
                return (s.color, lbl, tooltipFormatter(s.data[idx]))
            }

            ChartTooltip(values: items)
                .fixedSize()
                .position(x: min(max(xPos, chartLeftPad + 50), geo.size.width - 50), y: 20)
        }
    }
}

// MARK: - Gauge

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
