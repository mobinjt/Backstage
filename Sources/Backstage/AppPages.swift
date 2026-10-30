import BackstageCore
import Observation
import SwiftUI

/// Screens the app adds to the App tab with `Registry.addPage`. They live here rather than in
/// `Registry`, which BackstageCore keeps free of SwiftUI.
@MainActor
@Observable
final class AppPages {
    static let shared = AppPages()

    struct Page: Identifiable {
        let id = UUID()
        let title: String
        let group: String
        let systemImage: String?
        let content: @MainActor () -> AnyView
    }

    private(set) var pages: [Page] = []

    func add(_ page: Page) {
        pages.append(page)
    }
}

extension Registry {
    /// Adds a screen of the app's own, opened from a row in the App tab: a tool that needs more
    /// than a button, such as one that looks something up or tries out the app's data.
    public func addPage<Content: View>(
        _ title: String,
        group: String = "Pages",
        systemImage: String? = nil,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        AppPages.shared.add(AppPages.Page(title: title, group: group, systemImage: systemImage) { AnyView(content()) })
    }
}
