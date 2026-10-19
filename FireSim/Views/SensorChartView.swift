import SwiftUI
import Charts

/// Three time-series charts (temperature, visibility, CO) with tenability limits.
struct SensorChartView: View {
    @ObservedObject var controller: SimulationController
    /// Narrow screens: scroll the charts horizontally instead of squeezing them.
    var compact = false

    private struct Point: Identifiable {
        var id: String
        var sensor: String
        var time: Float
        var value: Float
    }

    private func points(_ keyPath: KeyPath<SensorSample, Float>) -> [Point] {
        var out: [Point] = []
        for sensor in controller.plan.sensors {
            let samples = controller.sensorHistory[sensor.id] ?? []
            // Thin dense histories so the charts stay responsive.
            let stride = max(1, samples.count / 400)
            for (i, s) in samples.enumerated() where i % stride == 0 {
                out.append(Point(id: "\(sensor.id)-\(s.id)", sensor: sensor.name, time: s.time, value: s[keyPath: keyPath]))
            }
        }
        return out
    }

    var body: some View {
        if compact {
            ScrollView(.horizontal) {
                charts
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 0)
            .frame(height: 170)
        } else {
            charts
                .frame(height: 190)
        }
    }

    private var charts: some View {
        HStack(spacing: 12) {
            chart(title: "온도 (°C)", data: points(\.temperatureC), limit: Tenability.maxTemperatureC, limitLabel: "60°C 한계")
            chart(title: "가시거리 (m)", data: points(\.visibilityM), limit: Tenability.minVisibilityM, limitLabel: "5 m 한계")
            chart(title: "CO (ppm)", data: points(\.coPPM), limit: Tenability.maxCOppm, limitLabel: "1200 ppm 한계")
        }
    }

    private func chart(title: String, data: [Point], limit: Float, limitLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Chart {
                ForEach(data) { p in
                    LineMark(x: .value("시간", p.time), y: .value(title, p.value))
                        .foregroundStyle(by: .value("센서", p.sensor))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("한계", limit))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(limitLabel).font(.caption2).foregroundColor(.red)
                    }
            }
            .chartXAxisLabel("시간 (s)")
            .chartLegend(position: .bottom, alignment: .leading)
        }
        .padding(8)
        .frame(width: compact ? 280 : nil)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}
