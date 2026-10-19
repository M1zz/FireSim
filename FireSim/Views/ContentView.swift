import SwiftUI

struct ContentView: View {
    @StateObject private var controller = SimulationController()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingPanel = false
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactLayout
        } else {
            regularLayout
        }
        #else
        regularLayout
            .frame(minWidth: 900, minHeight: 600)
        #endif
    }

    /// Top-down vs side view. Each view keeps its own edited floor plan.
    private var viewModePicker: some View {
        Picker("시점", selection: Binding(get: { controller.plan.viewMode },
                                          set: { controller.setViewMode($0) })) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Side-by-side layout for Mac and full-width iPad.
    private var regularLayout: some View {
        HStack(spacing: 0) {
            ControlPanel(controller: controller)
                .frame(width: 320)
            Divider()
            VStack(spacing: 12) {
                viewModePicker
                    .frame(maxWidth: 360)
                SimulationCanvas(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SensorChartView(controller: controller)
            }
            .padding(12)
        }
    }

    #if os(iOS)
    /// Stacked layout for iPhone and narrow iPad split view; controls live in a sheet.
    private var compactLayout: some View {
        VStack(spacing: 8) {
            HStack {
                Text("FireSim").font(.headline)
                Spacer()
                Button {
                    showingPanel = true
                } label: {
                    Label("설정", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }
            PlaybackBar(controller: controller)
            viewModePicker
            SimulationCanvas(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SensorChartView(controller: controller, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingPanel) {
            ControlPanel(controller: controller)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
    }
    #endif
}
