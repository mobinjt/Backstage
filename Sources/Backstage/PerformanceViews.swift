import BackstageCore
import Charts
import SwiftUI

/// The small overlay: frame rate, memory and CPU, with a flash when the main thread hangs.
struct PerformanceOverlayView: View {
    @State private var monitor = PerformanceMonitor.shared
    @State private var backstage = Backstage.shared
    @State private var flashesHang = false

    var body: some View {
        let sample = monitor.latest
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                metric(sample.map { String(format: "%.0f", $0.framesPerSecond) } ?? "–", unit: "fps", color: fpsColor(sample?.framesPerSecond))
                metric(sample.map { "\($0.droppedFrames)" } ?? "–", unit: "drop", color: (sample?.droppedFrames ?? 0) > 0 ? .orange : .white)
            }
            HStack(spacing: 8) {
                metric(sample.map { BackstageStyle.bytes(Int($0.memoryBytes)) } ?? "–", unit: "", color: .white)
                metric(sample.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "–", unit: "cpu", color: (sample?.cpuPercent ?? 0) > 80 ? .orange : .white)
            }
            Sparkline(values: monitor.samples.map(\.framesPerSecond), maximum: 120)
                .stroke(fpsColor(sample?.framesPerSecond), lineWidth: 1.5)
                .frame(width: 140, height: 18)
            if backstage.networkOverlay == .inPerformanceOverlay {
                NetworkLinesInPerformanceOverlay()
            }
        }
        .padding(8)
        .background(.black.opacity(0.75), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(flashesHang ? Color.red : .clear, lineWidth: 2)
        }
        .onChange(of: monitor.hangs.first?.id) { _, hang in
            guard hang != nil else { return }
            flashesHang = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                flashesHang = false
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Performance")
        .accessibilityHint("Opens Backstage")
        .accessibilityAddTraits(.isButton)
    }

    private func metric(_ value: String, unit: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func fpsColor(_ fps: Double?) -> Color {
        guard let fps else { return .white }
        if fps < 30 { return .red }
        if fps < 50 { return .orange }
        return .green
    }
}

#if os(iOS)
/// An overlay on iPhone and iPad: dragged anywhere and kept where it was left. A tap opens
/// Backstage on the tab it was last on; a long press offers to open it or hide the overlay.
struct DraggableOverlay<Content: View>: View {
    let reportFrame: (CGRect) -> Void
    let hide: () -> Void
    @ViewBuilder let content: Content
    @AppStorage private var x: Double
    @AppStorage private var y: Double
    @State private var dragOffset = CGSize.zero
    @State private var size = CGSize(width: 160, height: 70)

    /// `place` names where it's kept; `x` and `y` are where it starts, as fractions of the screen.
    init(place: String, x: Double, y: Double, reportFrame: @escaping (CGRect) -> Void, hide: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.reportFrame = reportFrame
        self.hide = hide
        self.content = content()
        _x = AppStorage(wrappedValue: x, "Backstage.\(place).x")
        _y = AppStorage(wrappedValue: y, "Backstage.\(place).y")
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .fixedSize()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    size = frame.size
                    reportFrame(frame)
                }
                .position(position(in: proxy.size))
                .onTapGesture { PanelView.open() }
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            x = min(max((proxy.size.width * x + value.translation.width) / proxy.size.width, 0.1), 0.9)
                            y = min(max((proxy.size.height * y + value.translation.height) / proxy.size.height, 0.05), 0.95)
                            dragOffset = .zero
                        }
                )
                .contextMenu {
                    Button("Open Backstage", systemImage: "wrench.and.screwdriver") { Backstage.shared.open() }
                    Button("Hide Overlay", systemImage: "eye.slash", action: hide)
                }
        }
    }

    /// Where it was left, kept fully on screen.
    private func position(in area: CGSize) -> CGPoint {
        let margin = 8.0
        let x = area.width * x + dragOffset.width
        let y = area.height * y + dragOffset.height
        return CGPoint(
            x: min(max(x, size.width / 2 + margin), area.width - size.width / 2 - margin),
            y: min(max(y, size.height / 2 + margin), area.height - size.height / 2 - margin)
        )
    }
}
#endif

/// A line through the last values, scaled to `maximum`.
struct Sparkline: Shape {
    let values: [Double]
    let maximum: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / Double(max(values.count - 1, 1))
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: Double(index) * step, y: rect.height * (1 - min(value / maximum, 1)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The Performance tab: the overlay switch, the last minute as charts, and recent hangs.
struct PerformanceView: View {
    @State private var backstage = Backstage.shared
    @State private var monitor = PerformanceMonitor.shared

    var body: some View {
        Form {
            Section {
                Toggle("Performance", isOn: Bindable(backstage).showsPerformanceOverlay)
                Picker("Network", selection: Bindable(backstage).networkOverlay) {
                    ForEach(Backstage.NetworkOverlayStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Alert on Failed or Slow Calls", isOn: Bindable(backstage).alertsOnNetworkProblems)
            } header: {
                Text("Overlays")
            } footer: {
                Text("Small windows above every screen; drag them anywhere, tap one to open Backstage. Performance shows the frame rate, dropped frames, memory and CPU. Network shows the calls in its own window, compact or as a list, or inside the performance one. Alerts appear at the bottom when a call fails or takes \(Int(NetworkActivity.slow)) s or more. They stay on across launches.")
            }
            Section {
                LabeledContent("Screen", value: "Up to \(PerformanceMonitor.screenMaximumFramesPerSecond) fps")
            } footer: {
                if PerformanceMonitor.isHeldTo60FramesPerSecond {
                    Text("iOS holds this app to 60 fps on this iPhone. To allow up to \(PerformanceMonitor.screenMaximumFramesPerSecond), set CADisableMinimumFrameDurationOnPhone to YES in the app's Info.plist.")
                        .foregroundStyle(.orange)
                }
            }
            if let latest = monitor.latest {
                Section("Now") {
                    LabeledContent("Frame rate", value: String(format: "%.0f fps", latest.framesPerSecond))
                    LabeledContent("Dropped frames", value: "\(latest.droppedFrames) in the last second")
                    LabeledContent("Memory", value: BackstageStyle.bytes(Int(latest.memoryBytes)))
                    LabeledContent("CPU", value: String(format: "%.0f%%", latest.cpuPercent))
                }
                Section("Last minute") {
                    chart("Frame rate", \.framesPerSecond, unit: "fps")
                    chart("Memory", { Double($0.memoryBytes) / 1_048_576 }, unit: "MB")
                    chart("CPU", \.cpuPercent, unit: "%")
                }
            }
            Section {
                if monitor.hangs.isEmpty {
                    Text("None so far").foregroundStyle(.secondary)
                }
                ForEach(monitor.hangs) { hang in
                    LabeledContent(hang.date.formatted(BackstageStyle.time), value: BackstageStyle.duration(hang.duration))
                }
            } header: {
                Text("Hangs")
            } footer: {
                Text("Times the main thread didn't respond for more than \(Int(PerformanceMonitor.hangThreshold * 1_000)) ms.")
            }
            IOSReportsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Performance")
        .onAppear { monitor.start() }
        .onDisappear {
            if !backstage.showsPerformanceOverlay { monitor.stop() }
        }
    }

    private func chart(_ title: String, _ value: @escaping (PerformanceMonitor.Sample) -> Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Chart(monitor.samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value(unit, value(sample)))
                    .foregroundStyle(BackstageStyle.accent)
            }
            .chartXAxis(.hidden)
            .frame(height: 80)
        }
        .padding(.vertical, 4)
    }
}
