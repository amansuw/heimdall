import SwiftUI

struct FanCurveView: View {
    @Environment(FanState.self) private var fan
    @Environment(SensorState.self) private var sensors
    @State private var curve = FanCurve()
    @State private var selectedSource = "AGG_CPU_AVG"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Fan Curve").font(.largeTitle).fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal)

                // Curve editor
                VStack(alignment: .leading, spacing: 12) {
                    Text("Temperature → Fan Speed").font(.headline)

                    // Canvas-based curve drawing
                    GeometryReader { geo in
                        let size = geo.size
                        Canvas { context, canvasSize in
                            let sorted = curve.sortedPoints
                            guard sorted.count >= 2 else { return }

                            // Grid lines
                            for i in stride(from: 0.0, through: 100.0, by: 25.0) {
                                let y = canvasSize.height - (CGFloat(i) / 100.0) * canvasSize.height
                                var gridPath = Path()
                                gridPath.move(to: CGPoint(x: 0, y: y))
                                gridPath.addLine(to: CGPoint(x: canvasSize.width, y: y))
                                context.stroke(gridPath, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                            }

                            for temp in stride(from: 30.0, through: 100.0, by: 10.0) {
                                let x = ((temp - 20) / 90) * canvasSize.width
                                var gridPath = Path()
                                gridPath.move(to: CGPoint(x: x, y: 0))
                                gridPath.addLine(to: CGPoint(x: x, y: canvasSize.height))
                                context.stroke(gridPath, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                            }

                            // Curve line
                            var linePath = Path()
                            for (i, point) in sorted.enumerated() {
                                let x = ((point.temperature - 20) / 90) * canvasSize.width
                                let y = canvasSize.height - (CGFloat(point.fanSpeed) / 100.0) * canvasSize.height
                                if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
                                else { linePath.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            context.stroke(linePath, with: .color(.blue), lineWidth: 2)

                            // Fill under curve
                            var fillPath = linePath
                            if let lastPoint = sorted.last {
                                let lastX = ((lastPoint.temperature - 20) / 90) * canvasSize.width
                                fillPath.addLine(to: CGPoint(x: lastX, y: canvasSize.height))
                            }
                            if let firstPoint = sorted.first {
                                let firstX = ((firstPoint.temperature - 20) / 90) * canvasSize.width
                                fillPath.addLine(to: CGPoint(x: firstX, y: canvasSize.height))
                            }
                            fillPath.closeSubpath()
                            context.fill(fillPath, with: .color(.blue.opacity(0.1)))

                            // Control points
                            for point in sorted {
                                let x = ((point.temperature - 20) / 90) * canvasSize.width
                                let y = canvasSize.height - (CGFloat(point.fanSpeed) / 100.0) * canvasSize.height
                                let circle = Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
                                context.fill(circle, with: .color(.blue))
                                context.stroke(circle, with: .color(.white), lineWidth: 2)
                            }

                            // Current temperature indicator
                            let currentTemp = sensors.averageCPUTemp
                            if currentTemp > 0 {
                                let curX = ((currentTemp - 20) / 90) * canvasSize.width
                                var indicatorPath = Path()
                                indicatorPath.move(to: CGPoint(x: curX, y: 0))
                                indicatorPath.addLine(to: CGPoint(x: curX, y: canvasSize.height))
                                context.stroke(indicatorPath, with: .color(.red.opacity(0.5)),
                                             style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                        }
                        .frame(height: 250)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    handleDrag(value: value, size: size)
                                }
                        )
                    }
                    .frame(height: 250)

                    // Axis labels
                    HStack {
                        Text("20°C").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Temperature").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("110°C").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Control points table
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Control Points").font(.headline)
                        Spacer()
                        Button(action: addPoint) {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(curve.sortedPoints) { point in
                        HStack {
                            Text(String(format: "%.0f°C", point.temperature)).font(.callout).frame(width: 50)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                            Text(String(format: "%.0f%%", point.fanSpeed)).font(.callout).frame(width: 50)
                            Spacer()
                            if curve.points.count > 2 {
                                Button(action: { removePoint(id: point.id) }) {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Apply button
                Button("Apply Curve") {
                    fan.activeCurve = curve
                    NotificationCenter.default.post(name: .fanControlModeChanged, object: FanControlMode.curve)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleDrag(value: DragGesture.Value, size: CGSize) {
        let temp = (value.location.x / size.width) * 90 + 20
        let speed = (1 - value.location.y / size.height) * 100
        let clampedTemp = max(20, min(110, temp))
        let clampedSpeed = max(0, min(100, speed))

        // Find nearest point
        if let nearest = curve.sortedPoints.min(by: { abs($0.temperature - clampedTemp) < abs($1.temperature - clampedTemp) }) {
            let dist = abs(nearest.temperature - clampedTemp)
            if dist < 8 {
                curve.updatePoint(id: nearest.id, temperature: clampedTemp, fanSpeed: clampedSpeed)
            }
        }
    }

    private func addPoint() {
        let sorted = curve.sortedPoints
        let midTemp = (sorted.first?.temperature ?? 30 + (sorted.last?.temperature ?? 90)) / 2
        curve.addPoint(CurvePoint(temperature: midTemp, fanSpeed: 50))
    }

    private func removePoint(id: UUID) {
        if let idx = curve.points.firstIndex(where: { $0.id == id }) {
            curve.removePoint(at: idx)
        }
    }
}
