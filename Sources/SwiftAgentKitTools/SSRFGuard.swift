//
//  SSRFGuard.swift
//  SwiftAgentKitTools
//
//  Blocks URLs that resolve to private, loopback, or link-local addresses so a
//  model-driven fetch (ImportSkillTool) cannot be steered at localhost services,
//  the LAN, or cloud metadata endpoints.
//

import Foundation

/// Classifies hosts as safe-to-fetch or blocked (private/loopback/link-local).
///
/// IP literals are checked directly. Hostnames are resolved and EVERY resolved
/// address must be public — one private A/AAAA record blocks the host. This is
/// resolve-time validation; it does not defend against a DNS answer changing
/// between validation and connection (rebinding), which would require
/// connect-by-validated-IP.
enum SSRFGuard {

    /// Returns a human-readable reason the host is blocked, or `nil` if it is
    /// acceptable. `resolve` maps a hostname to its IP-literal strings; the
    /// default uses getaddrinfo (real DNS) — tests inject a fake.
    static func blockReason(
        forHost host: String,
        resolve: (String) -> [String] = SSRFGuard.systemResolve
    ) -> String? {
        if let literal = literalBlockReason(forHost: host) { return literal }
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if isIPLiteral(trimmed) { return nil }

        // Hostname → every resolved address must be public.
        let addresses = resolve(trimmed)
        guard !addresses.isEmpty else { return "'\(host)' did not resolve" }
        for address in addresses {
            if let blocked = classifyLiteral(address.lowercased()) {
                return "'\(host)' resolves to a blocked address (\(blocked))"
            }
        }
        return nil
    }

    /// DNS-free subset of `blockReason`: catches local hostnames and IP
    /// literals only. A plain public-looking hostname passes — full resolution
    /// happens in the hardened default fetch path.
    static func literalBlockReason(forHost host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !trimmed.isEmpty else { return "empty host" }
        if trimmed == "localhost" || trimmed.hasSuffix(".localhost") || trimmed.hasSuffix(".local") {
            return "'\(host)' is a local hostname"
        }
        return classifyLiteral(trimmed)
    }

    // MARK: - Classification

    /// Returns a reason if `literal` parses as a blocked IP; `nil` when it is a
    /// public IP or not an IP literal at all.
    private static func classifyLiteral(_ literal: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            return isBlockedIPv4(v4) ? "\(literal) is a private/reserved IPv4 address" : nil
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            return isBlockedIPv6(v6) ? "\(literal) is a private/reserved IPv6 address" : nil
        }
        return nil
    }

    private static func isIPLiteral(_ literal: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return inet_pton(AF_INET, literal, &v4) == 1 || inet_pton(AF_INET6, literal, &v6) == 1
    }

    private static func isBlockedIPv4(_ addr: in_addr) -> Bool {
        let raw = UInt32(bigEndian: addr.s_addr)
        let a = UInt8((raw >> 24) & 0xff)
        let b = UInt8((raw >> 16) & 0xff)
        switch a {
        case 0, 10, 127: return true                       // "this" net, RFC1918, loopback
        case 100 where (64...127).contains(b): return true // CGNAT 100.64/10 (incl. some metadata svcs)
        case 169 where b == 254: return true               // link-local (cloud metadata 169.254.169.254)
        case 172 where (16...31).contains(b): return true  // RFC1918 172.16/12
        case 192 where b == 168: return true               // RFC1918 192.168/16
        default: return false
        }
    }

    private static func isBlockedIPv6(_ addr: in6_addr) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: addr) { raw in
            for i in 0..<16 { bytes[i] = raw[i] }
        }
        // ::1 loopback and :: unspecified
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) { return true }
        // fc00::/7 unique-local
        if bytes[0] & 0xfe == 0xfc { return true }
        // fe80::/10 link-local
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        // ::ffff:a.b.c.d — IPv4-mapped: defer to the IPv4 rules
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            var v4 = in_addr()
            let value = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            v4.s_addr = value.bigEndian
            return isBlockedIPv4(v4)
        }
        return false
    }

    // MARK: - Resolution

    /// Resolve a hostname to IP-literal strings via getaddrinfo (A + AAAA).
    static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(info) }

        var results: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                results.append(String(cString: buffer))
            }
            node = current.pointee.ai_next
        }
        return results
    }
}
