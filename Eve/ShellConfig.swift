import Foundation

/// Build-time configuration. Only https on port 443 is ever allowed (no ATS exceptions).
struct ShellConfig {
    static let shellVersion = "0.2.1"
    static let bridgeVersion = "1.1.0"

    let host: String
    let startURL: URL

    static let current: ShellConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = ((info["EveHost"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let path = (info["EveStartPath"] as? String) ?? "/ui/"
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = path
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), let url = c.url else {
            fatalError("EveHost must be a bare hostname (set it in Config/Local.xcconfig)")
        }
        return ShellConfig(host: host, startURL: url)
    }()

    /// Exact, component-wise match against the configured origin (https, host, 443).
    func isAllowed(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    func isAllowed(origin: (proto: String, host: String, port: Int)) -> Bool {
        origin.proto == "https" && origin.host.lowercased() == host && (origin.port == 0 || origin.port == 443)
    }
}
