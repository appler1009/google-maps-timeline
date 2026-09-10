import Foundation
import Network
import Observation

struct LuxDiscoveredHost: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let protocolVersion: Int
}

@Observable
@MainActor
final class LuxBonjourBrowser {
    private(set) var discovered: [LuxDiscoveredHost] = []
    private(set) var isSearching = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_lux-library._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.isSearching = false }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        discovered = results.compactMap { result in
            let serviceName: String
            if case .service(let name, _, _, _) = result.endpoint {
                serviceName = name
            } else {
                serviceName = result.endpoint.debugDescription
            }
            if case .bonjour(let txt) = result.metadata {
                let sid = txt.dictionary["sid"] ?? serviceName
                let host = txt.dictionary["host"] ?? serviceName
                let pv = Int(txt.dictionary["pv"] ?? "1") ?? 1
                return LuxDiscoveredHost(id: sid, name: host, endpoint: result.endpoint, protocolVersion: pv)
            }
            return LuxDiscoveredHost(id: serviceName, name: serviceName, endpoint: result.endpoint, protocolVersion: 1)
        }
        .sorted { $0.name < $1.name }
    }
}
