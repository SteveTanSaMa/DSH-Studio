//
//  HarnessURLPolicy.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Validates URLs used to communicate with the local Harness process.
public enum HarnessURLPolicy {
    /// The only host the app talks to; a literal IPv4 address avoids DNS resolution.
    public static let loopbackHost = "127.0.0.1"

    /// Allows only explicit HTTP(S) loopback URLs with a port and no credentials.
    ///
    /// A literal IPv4 host is intentional: accepting `localhost`, wildcard
    /// hosts, or embedded credentials would weaken the WebView boundary.
    public static func isAllowedLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host == loopbackHost,
              url.port != nil,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    /// Removes the one-time process token before constructing native API URLs.
    public static func baseURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}
