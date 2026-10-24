import BackstageCore
import SwiftUI

/// Objects still in memory after their screen closed, in the Performance tab.
struct LeaksSection: View {
    @State private var leaks: [LeakSuspect] = []

    var body: some View {
        Section {
            if leaks.isEmpty {
                Text("None so far").foregroundStyle(.secondary)
            }
            ForEach(leaks.reversed()) { leak in
                let stillThere = AppActivity.isStillInMemory(leak)
                LabeledContent {
                    Text(stillThere ? "Still in memory" : "Freed later")
                        .foregroundStyle(stillThere ? .purple : .secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leak.name).font(.subheadline.weight(.semibold))
                        Text("\(leak.expectedAt.formatted(BackstageStyle.time)), \(Int(leak.waited)) s after closing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Possible Leaks")
        } footer: {
            Text("The app's view controllers still in memory 3 s after they closed, and objects the app asked about with Backstage.expectRelease(of:). Xcode's Debug Memory Graph shows what holds one.")
        }
        .task {
            for await _ in AppActivity.leaks.changesIncludingNow() {
                leaks = AppActivity.leaks.events
            }
        }
    }
}
