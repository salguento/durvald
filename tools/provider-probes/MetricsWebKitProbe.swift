// Isolated app bundle used only by the external measurement executor.
import AppKit
import WebKit
func argument(_ key: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
guard let address = argument("--url"), let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
      let output = argument("--report"), let pidfile = argument("--pidfile"), let eventfile = argument("--events") else { fatalError("Expected isolated measurement arguments") }
final class Probe: NSObject, WKScriptMessageHandler {
    let output: String
    let eventfile: String
    init(output: String, eventfile: String) { self.output = output; self.eventfile = eventfile; super.init() }
    var window: NSWindow!
    var web: WKWebView?
    var events: [[String: Any]] = []
    var finished = false
    var checks: [String: Bool] = [:]
    let started = ProcessInfo.processInfo.systemUptime
    func record(_ event: [String: Any]) {
        var clean = event; clean["native_elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        events.append(clean)
        if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]), let handle = FileHandle(forWritingAtPath: eventfile) {
            handle.seekToEndOfFile();handle.write(data);handle.write(Data([10]));try? handle.close()
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let payload = message.body as? [String: Any], !finished else { return }
        if let value = payload["checks"] as? [String: Bool] { checks = value }
        if let name = payload["event"] as? String {
            var clean: [String: Any] = ["event":name]
            if let phase = payload["phase"] as? String { clean["phase"] = phase }
            for key in ["time","position","duration","code","stalls"] { if let value = payload[key] as? NSNumber { clean[key] = value } }
            record(clean)
        }
        if payload["done"] as? Bool == true { finish(payload["reason"] as? String ?? "unknown") }
    }
    func finish(_ reason: String) {
        guard !finished else { return };finished=true
        let status = !checks.isEmpty && checks.values.allSatisfy { $0 } ? "passed" : "limited"
        let report: [String: Any] = ["status":status,"reason":reason,"checks":checks,"events":events,"engine":"WKWebView","os":ProcessInfo.processInfo.operatingSystemVersionString,"captured_at":ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:output),options:.atomic) }
        web?.stopLoading();web?.configuration.userContentController.removeScriptMessageHandler(forName:"probe")
        web?.removeFromSuperview();web=nil;window.close()
        NSApp.stop(nil);NSApp.postEvent(NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0)!,atStart:false)
    }
}
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let probe=Probe(output: output, eventfile: eventfile)
FileManager.default.createFile(atPath:eventfile,contents:Data())
try String(ProcessInfo.processInfo.processIdentifier).write(toFile:pidfile,atomically:true,encoding:.utf8)
let configuration=WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.mediaTypesRequiringUserActionForPlayback = []
configuration.userContentController.add(probe,name:"probe")
probe.web=WKWebView(frame:NSRect(x:0,y:0,width:760,height:580),configuration:configuration)
probe.window=NSWindow(contentRect:probe.web!.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
probe.window.isReleasedWhenClosed=false
probe.window.title="Durvald — medição externa temporária"
probe.window.contentView=probe.web;probe.window.orderFront(nil)
probe.record(["event":"process_ready","phase":"unloaded_idle"])
Timer.scheduledTimer(withTimeInterval:5,repeats:false) { _ in probe.record(["event":"load_requested","phase":"loading"]);probe.web?.load(URLRequest(url:url)) }
Timer.scheduledTimer(withTimeInterval:85,repeats:false) { _ in probe.finish("native_deadline") }
app.run()
