import Foundation
import Observation

/// What the app adds to the panel: servers to switch between, information, actions and switches.
@MainActor
@Observable
public final class Registry {
    /// A server the app can use.
    public struct Server: Sendable, Hashable, Identifiable {
        public var name: String
        public var url: URL
        public var id: String { name }

        public init(_ name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    /// A choice between servers, read once at launch with `Backstage.server(for:)`.
    public struct ServerSetting: Sendable, Identifiable {
        public let key: String
        public let title: String
        /// The first is the app's own choice.
        public let servers: [Server]
        /// Lets the owner type another address, such as a server on the Mac.
        public let allowsCustomURL: Bool
        public var id: String { key }
    }

    public struct Info: Identifiable {
        public let id = UUID()
        public let title: String
        public let group: String
        public let value: @MainActor () -> String?
    }

    public struct Action: Identifiable {
        public let id = UUID()
        public let title: String
        public let group: String
        public let isDestructive: Bool
        public let perform: @MainActor () async -> Void
    }

    public struct Switch: Identifiable {
        public let key: String
        public let title: String
        public let group: String
        public let footnote: String?
        public var id: String { key }
    }

    public private(set) var serverSettings: [ServerSetting] = []
    public private(set) var info: [Info] = []
    public private(set) var actions: [Action] = []
    public private(set) var switches: [Switch] = []

    nonisolated init() {}

    // MARK: Adding

    /// Adds a server switch. The app reads the choice with `Backstage.server(for:)` when it starts.
    public func addServers(key: String, title: String = "Server", servers: [Server], allowsCustomURL: Bool = true) {
        serverSettings.removeAll { $0.key == key }
        serverSettings.append(ServerSetting(key: key, title: title, servers: servers, allowsCustomURL: allowsCustomURL))
    }

    /// Adds a line of information, read whenever the panel shows it.
    public func addInfo(_ title: String, group: String = "App", value: @escaping @MainActor () -> String?) {
        info.append(Info(title: title, group: group, value: value))
    }

    public func addAction(_ title: String, group: String = "Actions", isDestructive: Bool = false, perform: @escaping @MainActor () async -> Void) {
        actions.append(Action(title: title, group: group, isDestructive: isDestructive, perform: perform))
    }

    /// Adds an on/off switch; the app reads it with `Backstage.isOn(_:)`.
    public func addSwitch(_ title: String, key: String, group: String = "Switches", footnote: String? = nil) {
        switches.removeAll { $0.key == key }
        switches.append(Switch(key: key, title: title, group: group, footnote: footnote))
    }

    // MARK: Values

    nonisolated static func serverKey(_ key: String) -> String { "Backstage.server.\(key)" }
    nonisolated static func switchKey(_ key: String) -> String { "Backstage.switch.\(key)" }

    /// The chosen address for a server setting, or `nil` for the app's own choice.
    public func selectedServer(for key: String) -> URL? {
        UserDefaults.standard.string(forKey: Self.serverKey(key)).flatMap(URL.init(string:))
    }

    public func selectServer(_ url: URL?, for key: String) {
        UserDefaults.standard.set(url?.absoluteString, forKey: Self.serverKey(key))
    }

    public func isOn(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.switchKey(key))
    }

    public func set(_ key: String, on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.switchKey(key))
    }
}

extension Backstage {
    /// The server chosen in the panel for `key`, or `nil` to use the app's own. Only while
    /// Backstage applies at launch (Debug builds and unlocked devices), so App Store builds always
    /// use their own server.
    public nonisolated static func server(for key: String) -> URL? {
        guard isEnabledAtLaunch else { return nil }
        return UserDefaults.standard.string(forKey: Registry.serverKey(key)).flatMap(URL.init(string:))
    }

    /// A switch from the panel; always off while Backstage is off.
    public nonisolated static func isOn(_ key: String) -> Bool {
        guard isActive || isEnabledAtLaunch else { return false }
        return UserDefaults.standard.bool(forKey: Registry.switchKey(key))
    }
}
