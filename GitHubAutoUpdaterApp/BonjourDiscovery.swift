import Foundation
import Network

final class BonjourDiscoveryService: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    var onUpdate: (([DiscoveredServer]) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_ghupdater._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        onUpdate?([])
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        publish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        publish()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        publish()
    }

    private func publish() {
        let servers = services.compactMap { service -> DiscoveredServer? in
            guard let host = service.hostName, service.port > 0 else { return nil }
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let url = "http://\(cleanHost):\(service.port)"
            return DiscoveredServer(id: "\(service.name)-\(cleanHost)-\(service.port)", name: service.name, host: cleanHost, port: service.port, url: url)
        }.sorted { $0.name < $1.name }
        onUpdate?(servers)
    }
}
