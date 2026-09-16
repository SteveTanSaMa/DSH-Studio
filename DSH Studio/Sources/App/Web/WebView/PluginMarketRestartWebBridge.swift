//
//  PluginMarketRestartWebBridge.swift
//  DSH Studio
//

import Foundation

/// Routes dsh-market's restart action through DSH Studio's RuntimeManager.
/// The market's default endpoint forks a replacement Harness and terminates
/// the current process, which conflicts with the app-owned process supervisor.
enum PluginMarketRestartWebBridge {
    static let messageType = "pluginMarket.restart"

    static let source = """
    (() => {
      if (window.__dshStudioPluginMarketRestartBridgeInstalled) return;
      window.__dshStudioPluginMarketRestartBridgeInstalled = true;
      const nativeHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.deepseekStudio;
      const originalFetch = window.fetch.bind(window);
      window.fetch = function(input, init) {
        const requestURL = typeof input === 'string'
          ? input
          : input && typeof input.url === 'string'
            ? input.url
            : String(input || '');
        const requestMethod = String(
          (init && init.method) || (input && input.method) || 'GET'
        ).toUpperCase();
        let pathname = '';
        try { pathname = new URL(requestURL, window.location.href).pathname; } catch (_) {}
        if (nativeHandler && requestMethod === 'POST' && pathname === '/dsh-market/restart') {
          nativeHandler.postMessage({ type: "pluginMarket.restart" });
          return Promise.resolve(new Response(
            JSON.stringify({ ok: true, native: true }),
            { status: 202, headers: { 'content-type': 'application/json' } }
          ));
        }
        return originalFetch(input, init);
      };
    })();
    """
}
