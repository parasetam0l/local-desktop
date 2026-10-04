import Foundation
import Network

/// Bonjour discovery of LocalDesktop hosts on the local network.
struct DiscoveredHost: Identifiable, Equatable {
    /// Bonjour instance name, e.g. "MacBook Pro [A1B2]".
    let id: String
    let name: String
    var serverId: String? = nil
    let endpoint: NWEndpoint
}

@MainActor
final class HostBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var isSearching = true
    var onHostsChanged: (([DiscoveredHost]) -> Void)?

    private var browser: NWBrowser?
    private var searchTimeoutTimer: Timer?

    func start() {
        guard browser == nil else { return }
        isSearching = true
        #if targetEnvironment(simulator)
        let simEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                              port: NWEndpoint.Port(rawValue: RDService.defaultPort)!)
        let simHost = DiscoveredHost(id: "local_mac_sim",
                                     name: "Mac (Local Simulator)",
                                     endpoint: simEndpoint)
        hosts = [simHost]
        #endif
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: RDService.type, domain: nil), using: parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let items = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var serverId: String?
                if case let .bonjour(record) = result.metadata {
                    serverId = record["sid"]
                }
                return DiscoveredHost(id: name, name: name, serverId: serverId, endpoint: result.endpoint)
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                var allItems = items
                #if targetEnvironment(simulator)
                let simEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                                      port: NWEndpoint.Port(rawValue: RDService.defaultPort)!)
                let simHost = DiscoveredHost(id: "local_mac_sim",
                                             name: "Mac (Local Simulator)",
                                             endpoint: simEndpoint)
                if !allItems.contains(where: { $0.id == simHost.id }) {
                    allItems.insert(simHost, at: 0)
                }
                #endif
                self.hosts = allItems
                self.isSearching = false
                self.onHostsChanged?(allItems)
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                case .failed:
                    // Drop the dead browser so the next start() (pull to refresh,
                    // foregrounding) creates a fresh one.
                    self.browser?.cancel()
                    self.browser = nil
                    self.hosts = []
                    self.isSearching = false
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        b.start(queue: .main)
        browser = b

        searchTimeoutTimer?.invalidate()
        searchTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSearching = false
            }
        }
    }

    func stop() {
        searchTimeoutTimer?.invalidate()
        searchTimeoutTimer = nil
        browser?.cancel()
        browser = nil
        hosts = []
        isSearching = false
    }

    func restart() {
        stop()
        start()
    }
}
