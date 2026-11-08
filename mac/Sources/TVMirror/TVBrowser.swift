import Foundation
import Network

/// Finds TVs running the TVMirror app on the local network (Bonjour), like AirPlay's device list.
final class TVBrowser {
    struct TV: Hashable {
        let name: String
        let endpoint: NWEndpoint
    }

    private(set) var tvs: [TV] = []
    var onChange: (() -> Void)?
    private var browser: NWBrowser?

    func start() {
        let params = NWParameters.tcp
        let b = NWBrowser(for: .bonjour(type: tvServiceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let tvs = results.compactMap { result -> TV? in
                if case let .service(name, _, _, _) = result.endpoint { return TV(name: name, endpoint: result.endpoint) }
                return nil
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self?.tvs = tvs
            self?.onChange?()
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
            }
        }
        b.start(queue: .main)
        browser = b
    }
}
