import Backstage
import SwiftUI

struct ContentView: View {
    @State private var api = DemoAPI.shared
    @State private var socket = EchoSocket()

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
