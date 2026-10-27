// Standalone development proof; no Durvald database, cookies or credentials.
import AppKit
import WebKit

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}
guard let address = argument("--url"), let url = URL(string: address),
      url.scheme == "http", url.host == "127.0.0.1",
      let output = argument("--report") else { fatalError("Expected loopback --url and --report") }
let limit = min(120, max(10, Double(argument("--timeout") ?? "60") ?? 60))
final class Probe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let output: String
    init(output: String) { self.output = output; super.init() }
    var window: NSWindow!
    var web: WKWebView!
    var finished = false
    var events: [[String: Any]] = []
    var latestChecks: [String: Bool] = [:]
    var userAgent = "unknown"
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let payload = message.body as? [String: Any] else { return }
        if let checks = payload["checks"] as? [String: Bool] { latestChecks = checks }
        if let event = payload["event"] as? String, ["ready", "playing", "paused", "resumed", "seek", "ended", "error", "timeout"].contains(event) {
            var clean: [String: Any] = ["event": event]
            for key in ["time", "position", "duration", "code"] { if let value = payload[key] as? NSNumber { clean[key] = value } }
            if events.count < 100 { events.append(clean) }
        }
        if payload["done"] as? Bool == true {
            let checks = payload["checks"] as? [String: Bool] ?? [:]
            finish(checks.isEmpty ? "failed" : checks.values.allSatisfy { $0 } ? "passed" : "failed", checks: checks)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        events.append(["event": "page_loaded"])
        webView.evaluateJavaScript("navigator.userAgent") { value, error in
            self.events.append(["event": "script_context", "available": error == nil && value != nil])
            if let text = value as? String, text.count < 500 { self.userAgent = text }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        events.append(["event": "navigation_failed", "code": (error as NSError).code])
        finish("failed")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        events.append(["event": "navigation_failed", "code": (error as NSError).code])
        finish("failed")
    }
    func finish(_ status: String, checks: [String: Bool] = [:]) {
        guard !finished else { return }; finished = true
        let observed = checks.isEmpty ? latestChecks : checks
        let basic = ["ready", "play", "progress", "pause", "resume", "seek"].allSatisfy { observed[$0] == true }
        let outcome = basic && observed["ended"] != true ? "limited" : status
        let report: [String: Any] = ["schema_version": 1, "status": outcome, "engine": "WKWebView", "user_agent": userAgent, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "captured_at": ISO8601DateFormatter().string(from: Date()), "events": events, "checks": observed,
            "environment": "development_process_nonpersistent_store", "distribution_sandbox_notarization": "not_validated"]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic) }
        catch { fputs("Unable to write probe report\n", stderr) }
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let probe = Probe(output: output)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.mediaTypesRequiringUserActionForPlayback = []
configuration.userContentController.add(probe, name: "probe")
probe.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 580), configuration: configuration)
probe.web.navigationDelegate = probe
probe.window = NSWindow(contentRect: probe.web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
probe.window.title = "Durvald — prova técnica do player oficial"
probe.window.contentView = probe.web
probe.window.orderFront(nil)
probe.web.load(URLRequest(url: url))
Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { _ in probe.finish("inconclusive") }
application.run()
