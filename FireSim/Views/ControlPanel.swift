import SwiftUI
import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct ControlPanel: View {
    @ObservedObject var controller: SimulationController
    @State private var exportingCSV = false
    @State private var csvDocument = CSVDocument(text: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                playbackSection
                Divider()
                displaySection
                Divider()
                editSection
                Divider()
                firesSection
                Divider()
                ventsSection
                Divider()
                offlineSection
                Divider()
                dataSection
            }
            .padding(14)
        }
        .fileExporter(isPresented: $exportingCSV, document: csvDocument,
                      contentType: .commaSeparatedText, defaultFilename: "firesim_sensors") { _ in }
    }

    // MARK: Sections

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("시뮬레이션").font(.headline)
            PlaybackBar(controller: controller)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("표시").font(.headline)
            Picker("표시", selection: $controller.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(controller.plan.viewMode == .section
                 ? "단면: 부력이 화면 위쪽으로 작용합니다. 연기층 형성·천장 제트 관찰용."
                 : "평면: 부력은 평면 밖 방향이므로 열팽창 밀어냄으로 근사합니다. 연기 확산 경로 관찰용.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Text("해상도").frame(width: 80, alignment: .leading)
                Picker("해상도", selection: $controller.resolution) {
                    ForEach([128, 192, 256, 384], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
            HStack {
                Text("압력 반복 \(controller.jacobiIterations)").frame(width: 100, alignment: .leading)
                Slider(value: Binding(get: { Double(controller.jacobiIterations) },
                                      set: { controller.jacobiIterations = Int($0) }), in: 10...120, step: 10)
            }
        }
    }

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("편집 모드").font(.headline)
            Picker("편집", selection: $controller.editMode) {
                ForEach(EditMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(editHint).font(.caption).foregroundColor(.secondary)
            HStack {
                Button("단면 예시") { controller.loadPreset(.demoSection()) }
                Button("평면 예시") { controller.loadPreset(.demoPlan()) }
                Button("모두 지우기") {
                    var p = controller.plan
                    p.elements = []; p.fires = []; p.sensors = []
                    controller.loadPreset(p)
                }
            }
        }
    }

    private var editHint: String {
        switch controller.editMode {
        case .wall, .door, .window: return "화면을 드래그해 선을 그립니다. 문/창은 벽 위에 그리면 개구부가 됩니다."
        case .fire: return "탭한 위치에 발화점을 놓습니다. 아래 기본값이 적용됩니다."
        case .sensor: return "탭한 위치에 센서를 놓습니다. 온도·가시거리·CO를 기록합니다."
        case .toggle: return "문·창을 탭해 열고 닫습니다. 열린 창은 외기로 연기를 배출합니다."
        case .erase: return "탭한 곳 근처의 발화점·센서·선을 삭제합니다."
        }
    }

    private var firesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("발화점").font(.headline)
            Group {
                Text("새 발화점 기본값").font(.caption).foregroundColor(.secondary)
                Picker("성장", selection: $controller.newFireGrowth) {
                    ForEach(FireGrowth.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("최대 HRR \(Int(controller.newFireMaxHRR)) kW").frame(width: 140, alignment: .leading)
                    Slider(value: $controller.newFireMaxHRR, in: 100...5000, step: 100)
                }
                HStack {
                    Text(String(format: "반경 %.1f m", controller.newFireRadius)).frame(width: 140, alignment: .leading)
                    Slider(value: $controller.newFireRadius, in: 0.2...2, step: 0.1)
                }
            }
            ForEach($controller.plan.fires) { $fire in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "(%.1f, %.1f) · 현재 %.0f kW", fire.position.x, fire.position.y, fire.hrr(at: controller.simTime)))
                        .font(.caption.bold())
                    Picker("성장", selection: $fire.growth) {
                        ForEach(FireGrowth.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    HStack {
                        Text("최대 \(Int(fire.maxHRR)) kW").frame(width: 110, alignment: .leading)
                        Slider(value: $fire.maxHRR, in: 100...5000, step: 100)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var ventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("문 · 창 개폐").font(.headline)
            let openings = controller.plan.elements.indices.filter { controller.plan.elements[$0].kind != .wall }
            if openings.isEmpty {
                Text("문이나 창이 없습니다.").font(.caption).foregroundColor(.secondary)
            }
            ForEach(openings, id: \.self) { i in
                let e = controller.plan.elements[i]
                Toggle(isOn: Binding(get: { controller.plan.elements[i].isOpen },
                                     set: { controller.plan.elements[i].isOpen = $0 })) {
                    Text(String(format: "%@ (%.1f, %.1f)", e.kind.label, (e.start.x + e.end.x) / 2, (e.start.y + e.end.y) / 2))
                        .font(.caption)
                }
            }
        }
    }

    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("고해상도 오프라인 계산").font(.headline)
            Text("더 조밀한 격자(기본 512), 240 Hz 서브스텝, 80회 압력 반복으로 계산한 뒤 재생합니다. 현재 표시 모드로 렌더됩니다.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Text("길이 \(Int(controller.offlineDuration)) s").frame(width: 90, alignment: .leading)
                Slider(value: $controller.offlineDuration, in: 10...180, step: 10)
            }
            HStack {
                Text("해상도").frame(width: 90, alignment: .leading)
                Picker("", selection: $controller.offlineResolution) {
                    ForEach([384, 512, 768], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
            if let progress = controller.offlineProgress {
                ProgressView(value: progress)
                Button("취소") { controller.cancelOffline() }
            } else {
                Button("계산 시작") { controller.runOffline() }
            }
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("데이터").font(.headline)
            Text("센서별 온도·가시거리·CO 시계열. 한계값: 60°C, 5 m, 1200 ppm (SFPE 계열 경험칙).")
                .font(.caption).foregroundColor(.secondary)
            Button("CSV 내보내기") { csvDocument = CSVDocument(text: controller.csv()); exportingCSV = true }
                .disabled(controller.sensorHistory.isEmpty)
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
