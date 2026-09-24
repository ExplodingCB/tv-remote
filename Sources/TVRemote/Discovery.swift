import Foundation

/// Finds Apple TVs through the system's Bonjour service (mDNSResponder).
/// pyatv's own multicast scanner comes up empty on some networks, so the app
/// resolves addresses here and has pyatv query those hosts directly.
@MainActor
final class Discovery: NSObject {
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private(set) var hosts: [String: String] = [:]  // service name -> IP

    var onChange: (() -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_companion-link._tcp.", inDomain: "local.")
    }

    /// Resolved addresses, waiting briefly if a browse has only just started.
    func addresses(waitingUpTo timeout: TimeInterval = 2) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while hosts.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Array(Set(hosts.values)).sorted()
    }

    fileprivate func found(_ service: NetService) {
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    fileprivate func removed(_ service: NetService) {
        services[service.name] = nil
        hosts[service.name] = nil
        onChange?()
    }

    fileprivate func resolved(_ service: NetService) {
        let addresses = (service.addresses ?? []).compactMap(Self.numericHost)
        // Prefer IPv4; link-local IPv6 needs a scope pyatv can't use.
        guard let address = addresses.first(where: { !$0.contains(":") })
            ?? addresses.first(where: { !$0.lowercased().hasPrefix("fe80") }) else { return }
        if hosts[service.name] != address {
            hosts[service.name] = address
            onChange?()
        }
    }

    private static func numericHost(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sockaddr = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sockaddr, socklen_t(data.count), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
    }
}

extension Discovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { found(service) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { removed(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { resolved(sender) }
    }
}
