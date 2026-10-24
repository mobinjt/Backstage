import Backstage
import SwiftUI
import UserNotifications

struct ContentView: View {
    @State private var api = DemoAPI.shared
    @State private var socket = EchoSocket()
    @State private var demo = DemoState.shared
    @State private var whereAmI = WhereAmI.shared
    /// Whether the receipt shown leaks; `nil` while none is shown.
    @State private var receipt: ReceiptKind?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DemoAPI.Request.allCases) { request in
                        Button {
                            Task { await api.send(request) }
                        } label: {
                            LabeledContent {
                                if api.running.contains(request) {
                                    ProgressView()
                                } else if let result = api.results[request] {
                                    Text(result)
                                        .monospacedDigit()
                                        .foregroundStyle(color(for: result))
                                }
                            } label: {
                                Label(request.title, systemImage: request.systemImage)
                            }
                        }
                    }
                    Button("Send All", systemImage: "paperplane") {
                        Task { await api.sendAll() }
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text("Each call shows up in Backstage's Network tab with its status, timing, headers and body.")
                }

                Section {
                    if socket.isOpen {
                        Button("Send a Message", systemImage: "arrow.up.message") {
                            Task { await socket.sendGreeting() }
                        }
                        if let reply = socket.lastReply {
                            LabeledContent("Echo", value: reply)
                                .lineLimit(2)
                        }
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                            socket.disconnect()
                        }
                    } else {
                        Button("Connect to the Echo Server", systemImage: "bolt.horizontal") {
                            socket.connect()
                        }
                    }
                    Button("Simulate a Nearby Peer", systemImage: "iphone.radiowaves.left.and.right") {
                        Task { await NearbyPeer.simulate() }
                    }
                } header: {
                    Text("Connections")
                } footer: {
                    Text("WebSockets and other connections are reported by the app and show with their messages.")
                }

                Section {
                    Button("Freeze for Half a Second", systemImage: "snowflake") {
                        Thread.sleep(forTimeInterval: 0.6)
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Turn on the overlay in Backstage's Performance tab. It flashes red when the main thread hangs.")
                }

                Section {
                    NavigationLink {
                        OrderDetailScreen()
                    } label: {
                        Label("Open a Named Screen", systemImage: "doc.text")
                    }
                    #if os(iOS)
                    Button("Open a Leaking Screen", systemImage: "drop") { receipt = .leaking }
                    Button("Open a Well-Behaved Screen", systemImage: "checkmark.seal") { receipt = .wellBehaved }
                    #endif
                    Button("Allow Notifications", systemImage: "bell") {
                        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                    }
                    Button {
                        whereAmI.ask()
                    } label: {
                        LabeledContent {
                            Text(whereAmI.answer ?? "")
                        } label: {
                            Label("Where Am I?", systemImage: "location")
                        }
                    }
                    NavigationLink {
                        MapScreen()
                    } label: {
                        Label("Open a Map", systemImage: "map")
                    }
                    LabeledContent("Last Notification", value: demo.lastNotification ?? "None")
                    LabeledContent("Last Link", value: demo.lastLink ?? "None")
                        .lineLimit(2)
                } header: {
                    Text("Try Backstage")
                } footer: {
                    Text("Screens show in the Timeline. The leaking screen shows under Performance > Possible Leaks. In Tools: send a test notification, open backstage-example://orders/42 as a deep link, set a location for Where Am I?, change the look, slow animations or show touches, or Report a Bug from any tab.")
                }

                Section {
                    LabeledContent("Version", value: "1.0 (1)")
                        .backstageTrigger()
                    LabeledContent("Server", value: api.baseURL.host() ?? api.baseURL.absoluteString)
                } header: {
                    Text("About")
                } footer: {
                    Text("Tap Version seven times, shake the device, or press ⌃⌥⌘D to open Backstage. In a TestFlight build the same taps ask for the passphrase, which is backstage-example here.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Backstage Example")
            .onOpenURL { url in demo.lastLink = url.absoluteString }
            #if os(iOS)
            .sheet(item: $receipt) { kind in
                ReceiptScreen(leaks: kind == .leaking)
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open Backstage", systemImage: "wrench.and.screwdriver") {
                        Backstage.shared.open()
                    }
                }
            }
        }
    }

    private func color(for result: String) -> Color {
        switch Int(result) ?? 0 {
        case 200..<300: .green
        case 300..<400: .secondary
        case 400..<500: .orange
        case 500...: .red
        default: result == "Mock" ? .secondary : .red
        }
    }
}
