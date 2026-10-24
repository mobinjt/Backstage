import BackstageCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Report a Bug: what's on screen, marked up, with everything Backstage knows, in one package to
/// share.
@MainActor
@Observable
final class BugReportModel {
    static let shared = BugReportModel()

    var isPresented = false
    /// The app's screen when the report was started, without Backstage on top.
    private(set) var screenshot: PlatformImage?

    /// Takes the screenshot and opens the report, opening the panel first if it's closed.
    func start() {
        screenshot = Self.captureApp()
        if !Backstage.shared.isPanelPresented {
            Backstage.shared.open()
        }
        isPresented = true
    }

    /// The app's own windows, not Backstage's.
    static func captureApp() -> PlatformImage? {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        let windows = scene.windows.filter { !($0 is PassthroughWindow) && !$0.isHidden }.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard let bounds = windows.first?.bounds else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            for window in windows {
                window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
            }
        }
        #elseif os(macOS)
        let window = NSApp.mainWindow.flatMap { $0.title == "Backstage" ? nil : $0 }
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.title != "Backstage" }
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
        #endif
    }
}

/// Writing the report: what happened, marks on the screenshot, and what goes with it.
struct BugReportView: View {
    @State private var model = BugReportModel.shared
    @State private var whatHappened = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var includesScreenshot = true
    @State private var includesNetwork = true
    @State private var includesLogs = true
    @State private var includesTimeline = true
    @FocusState private var isWriting: Bool
    /// Read once the report opens, so sharing doesn't wait for them.
    @State private var logs: [LogEntry]?
    @State private var isPreparing = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("What happened?") {
                    TextField("Steps, what you expected, what happened instead", text: $whatHappened, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($isWriting)
                }
                if let screenshot = model.screenshot {
                    Section {
                        MarkupCanvas(image: screenshot, strokes: $strokes)
                            .frame(maxWidth: .infinity)
                            .frame(height: 340)
                        HStack {
                            Button("Undo", systemImage: "arrow.uturn.backward") { _ = strokes.popLast() }
                                .disabled(strokes.isEmpty)
                            Spacer()
                            Button("Clear", systemImage: "xmark.circle") { strokes = [] }
                                .disabled(strokes.isEmpty)
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text("Screenshot")
                    } footer: {
                        Text("Draw on it to point at the problem.")
                    }
                }
                Section {
                    if model.screenshot != nil {
                        Toggle("Screenshot", isOn: $includesScreenshot)
                    }
                    Toggle("Network Calls (HAR)", isOn: $includesNetwork)
                    Toggle("Logs", isOn: $includesLogs)
                    Toggle("Timeline", isOn: $includesTimeline)
                    LabeledContent("Build, Device and Settings", value: "Always")
                } header: {
                    Text("Include")
                } footer: {
                    Text("From this launch. Authorization headers, cookies and API keys are left out of the calls.")
                }
                Section {
                    Button(action: share) {
                        HStack {
                            Label(isPreparing ? "Preparing Report…" : "Share Report", systemImage: "square.and.arrow.up")
                            if isPreparing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPreparing)
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("A zip with the report, screenshot, calls, logs and timeline, to send by Mail, Slack or AirDrop or attach to an issue.")
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Report a Bug")
            .task { logs = try? await LogReader.entries() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isWriting = false }
                }
                #endif
            }
        }
    }

    private var package: BugReportPackage {
        BugReportPackage(
            whatHappened: whatHappened,
            screenshot: includesScreenshot ? model.screenshot.map { MarkedUpScreenshot(image: $0, strokes: strokes) } : nil,
            includesNetwork: includesNetwork,
            includesLogs: includesLogs,
            includesTimeline: includesTimeline,
            details: BugReportPackage.details(),
            sensitiveHeaders: Backstage.shared.configuration?.sensitiveHeaders ?? [],
            logs: logs
        )
    }

    /// Makes the zip, then opens the share sheet with it.
    private func share() {
        isWriting = false
        isPreparing = true
        failure = nil
        let package = package
        Task {
            defer { isPreparing = false }
            do {
                let zip = try await package.zip()
                ShareSheet.present([zip, package.summary], subject: package.title)
            } catch {
                failure = "Couldn't make the report: \(error.localizedDescription)"
            }
        }
    }
}

/// The screenshot with a finger or mouse drawing on it.
struct MarkupCanvas: View {
    let image: PlatformImage
    @Binding var strokes: [[CGPoint]]

    var body: some View {
        GeometryReader { proxy in
            let size = Self.fitted(image.size, in: proxy.size)
            ZStack {
                Self.picture(image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                Self.marks(strokes, in: size)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Kept as fractions of the picture, so they fit it at any size.
                        let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                        if value.translation == .zero || strokes.isEmpty {
                            strokes.append([point])
                        } else {
                            strokes[strokes.count - 1].append(point)
                        }
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func picture(_ image: PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #elseif os(macOS)
        Image(nsImage: image)
        #endif
    }

    static func marks(_ strokes: [[CGPoint]], in size: CGSize) -> some View {
        Canvas { context, _ in
            for stroke in strokes {
                var path = Path()
                for (index, point) in stroke.enumerated() {
                    let scaled = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
                }
                if stroke.count == 1, let point = stroke.first {
                    path.addEllipse(in: CGRect(x: point.x * size.width - 2, y: point.y * size.height - 2, width: 4, height: 4))
                }
                context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: max(size.width / 120, 3), lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }

    static func fitted(_ size: CGSize, in area: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The screenshot with the marks drawn in, at its full size, as PNG.
    @MainActor
    static func png(of image: PlatformImage, strokes: [[CGPoint]]) -> Data? {
        let size = image.size
        let renderer = ImageRenderer(content: ZStack {
            picture(image).resizable()
            marks(strokes, in: size)
        }.frame(width: size.width, height: size.height))
        #if os(iOS)
        renderer.scale = image.scale
        #endif
        guard let cgImage = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The screenshot and the marks on it, drawn together only when the report is shared.
struct MarkedUpScreenshot: @unchecked Sendable {
    /// Only read on the main actor.
    let image: PlatformImage
    let strokes: [[CGPoint]]
}

/// The report, made into a zip to share.
struct BugReportPackage: Sendable {
    var whatHappened: String
    var screenshot: MarkedUpScreenshot?
    var includesNetwork: Bool
    var includesLogs: Bool
    var includesTimeline: Bool
    var details: String
    var sensitiveHeaders: Set<String>
    /// Read earlier; `nil` reads them now.
    var logs: [LogEntry]?

    var title: String {
        let first = whatHappened.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? "Bug report: \(Self.appName)" : first
    }

    /// The text that goes with the zip, such as a message's body.
    var summary: String {
        [whatHappened.isEmpty ? nil : whatHappened, details].compactMap { $0 }.joined(separator: "\n\n")
    }

    func zip() async throws -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let name = "Bug Report \(stamp)"
        let folder = URL.temporaryDirectory.appending(path: "Backstage/\(name)", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        Self.removeOldReports()
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        try Data(summary.utf8).write(to: folder.appending(path: "Report.txt"))
        if let screenshot, let png = await MainActor.run(body: { MarkupCanvas.png(of: screenshot.image, strokes: screenshot.strokes) }) {
            try png.write(to: folder.appending(path: "Screenshot.png"))
        }
        if includesNetwork {
            let launch = NetworkRecorder.shared.launchID
            let calls = NetworkRecorder.shared.transactions.filter { $0.launchID == launch }
            try NetworkExport.har(calls, sensitiveHeaders: sensitiveHeaders).write(to: folder.appending(path: "Network.har"))
        }
        if includesLogs, let entries = try? await logsToInclude() {
            let lines = entries.filter(\.isFromApp).map { entry in
                "\(entry.date.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(entry.level.title)] \(entry.category.isEmpty ? entry.subsystem : entry.category): \(entry.message)"
            }
            try Data(lines.joined(separator: "\n").utf8).write(to: folder.appending(path: "Logs.txt"))
        }
        if includesTimeline {
            let timeline = await MainActor.run { TimelineModel.shared.text(since: Date.now.addingTimeInterval(-30 * 60)) }
            try Data(timeline.utf8).write(to: folder.appending(path: "Timeline.txt"))
        }

        // A folder read "for uploading" comes back zipped.
        let zip = URL.temporaryDirectory.appending(path: "Backstage/\(name).zip")
        try? fileManager.removeItem(at: zip)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try fileManager.copyItem(at: zipped, to: zip)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return zip
    }

    private func logsToInclude() async throws -> [LogEntry] {
        if let logs { return logs }
        return try await LogReader.entries()
    }

    /// Reports made more than ten minutes ago; the share sheet may still be reading newer ones.
    static func removeOldReports() {
        let folder = URL.temporaryDirectory.appending(path: "Backstage", directoryHint: .isDirectory)
        let oldest = Date.now.addingTimeInterval(-10 * 60)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for item in items where item.lastPathComponent.hasPrefix("Bug Report") {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < oldest { try? FileManager.default.removeItem(at: item) }
        }
    }

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "the app"
    }

    /// The build, device and Backstage's settings, as lines of text.
    @MainActor
    static func details() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let backstage = Backstage.shared
        let registry = backstage.registry
        var lines = [
            "App: \(appName) \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")), \(Bundle.main.bundleIdentifier ?? "?")",
            "Runs from: \(backstage.environment.map(AppTabView.title) ?? "?")",
            "Device: \(DeviceInfo.model), \(DeviceInfo.system)",
            "Language: \(Locale.preferredLanguages.first ?? "?"), region \(Locale.current.region?.identifier ?? "?"), \(TimeZone.current.identifier)",
            "Reported: \(Date.now.formatted(date: .abbreviated, time: .standard))"
        ]
        for setting in registry.serverSettings {
            let inUse = registry.serverInUse(for: setting.key)
            let name = inUse.map { url in setting.servers.first { $0.url == url }?.name ?? url.absoluteString } ?? setting.servers.first?.name ?? "?"
            lines.append("\(setting.title): \(name)")
        }
        let switches = registry.switches.filter { registry.isOn($0.key) }.map(\.title)
        if !switches.isEmpty {
            lines.append("Switches on: \(switches.joined(separator: ", "))")
        }
        if let simulation = SimulationModel.shared.summary {
            lines.append("Simulating: \(simulation)")
        }
        if let place = LocationModel.shared.location {
            lines.append("Location: \(place.name) (\(String(format: "%.4f, %.4f", place.latitude, place.longitude))), time zone \(place.timeZone.identifier)")
        }
        let tools = DeviceTools.shared
        if tools.isChangingAnything {
            var changes: [String] = []
            if tools.appearance != .system { changes.append(tools.appearance.title) }
            if let size = tools.textSize { changes.append("text size \(size)") }
            if tools.rightToLeft { changes.append("right to left") }
            if tools.boldText { changes.append("bold text") }
            if tools.animationSpeed != 1 { changes.append("animations at \(tools.animationSpeed)×") }
            if let language = tools.language { changes.append("language \(language)") }
            if let region = tools.region { changes.append("region \(region)") }
            if !changes.isEmpty { lines.append("Testing changes: \(changes.joined(separator: ", "))") }
        }
        return lines.joined(separator: "\n")
    }
}

/// The system's share sheet for files and text, from Backstage's own window.
@MainActor
enum ShareSheet {
    static func present(_ items: [Any], subject: String) {
        #if os(iOS)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
            var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        // The text gives a Mail message its subject.
        let shared = items.map { item -> Any in
            guard let text = item as? String else { return item }
            return SharedText(text: text, subject: subject)
        }
        let sheet = UIActivityViewController(activityItems: shared, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            // On iPad it points at the middle of the screen.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
        #elseif os(macOS)
        guard let view = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: items).show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
        #endif
    }
}

#if os(iOS)
/// Text to share, with a subject for Mail.
private final class SharedText: NSObject, UIActivityItemSource {
    let text: String
    let subject: String

    init(text: String, subject: String) {
        self.text = text
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { subject }
}
#endif
