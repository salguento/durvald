import AppKit
import Observation
import SwiftUI
import WebKit

/// The Rust callback runs off the main thread. Stop acknowledges WebKit's media
/// suspension before Rust is allowed to start native audio.
final class EmbeddedPlaybackBridge: EmbeddedPlaybackHost {
    private let owner: EmbeddedPlayerController
    init(owner: EmbeddedPlayerController) { self.owner = owner }
    func execute(command: EmbeddedPlaybackCommand) -> Bool {
        guard !Thread.isMainThread else { return false }
        let done = DispatchSemaphore(value: 0)
        var accepted = false
        DispatchQueue.main.async { [owner] in
            owner.execute(command) { result in accepted = result; done.signal() }
        }
        return done.wait(timeout: .now() + 8) == .success && accepted
    }
}

@MainActor @Observable
final class EmbeddedPlayerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var webView: WKWebView?
    private(set) var sourceStatus: PlaybackSourceStatus?
    private(set) var status: EmbeddedPlaybackSnapshot?
    @ObservationIgnored weak var core: DurvaldCore?
    @ObservationIgnored private var generation: String?
    @ObservationIgnored private var pendingCommands: [EmbeddedPlaybackCommand] = []
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let pageBuilder: (String, Double) -> String
    init(pageBuilder: @escaping (String, Double) -> String = EmbeddedPlayerController.html) {
        self.pageBuilder = pageBuilder
        super.init()
    }

    func connect(to core: DurvaldCore) async throws {
        self.core = core
        try await core.setEmbeddedPlaybackHost(host: EmbeddedPlaybackBridge(owner: self))
    }
    func refresh() async {
        guard let core else { return }
        status = await core.embeddedPlayback()
        sourceStatus = await core.playbackSourceStatus()
    }
    func execute(_ command: EmbeddedPlaybackCommand, completion: @escaping (Bool) -> Void) {
        if command.kind == .stop {
            guard generation == command.generation, let view = webView else { completion(true); return }
            view.setAllMediaPlaybackSuspended(true) { [weak self, weak view] in
                guard let self else { completion(true); return }
                if self.webView === view {
                    view?.stopLoading()
                    view?.configuration.userContentController.removeScriptMessageHandler(forName: "durvaldPlayback")
                    self.webView = nil; self.generation = nil; self.pendingCommands = []
                }
                completion(true)
            }
            return
        }
        if command.kind == .load {
            guard webView == nil, let url = command.url,
                  let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "soundcloud.com" else { completion(false); return }
            generation = command.generation; sequence = 0; pendingCommands = []
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.userContentController.add(self, name: "durvaldPlayback")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            webView = view
            view.loadHTMLString(pageBuilder(url, command.value), baseURL: URL(string: "https://w.soundcloud.com"))
            completion(true)
            return
        }
        guard generation == command.generation, let view = webView else { completion(false); return }
        apply(command, to: view)
        completion(true)
    }
    private func apply(_ command: EmbeddedPlaybackCommand, to view: WKWebView) {
        let name: String
        switch command.kind {
        case .play: name = "play"
        case .pause: name = "pause"
        case .seek: name = "seek"
        case .volume: name = "volume"
        default: return
        }
        let value = command.value.isFinite ? command.value : 0
        let javascript = "typeof window.durvaldCommand === 'function' ? (window.durvaldCommand('\(name)', \(value)), true) : false;"
        view.evaluateJavaScript(javascript) { [weak self, weak view] result, error in
            guard let self, let view, self.webView === view, self.generation == command.generation else { return }
            if error != nil { self.publish(kind: .failed, position: 0, duration: nil) }
            else if result as? Bool != true {
                // At most one pending intent per category while the parent page loads.
                self.pendingCommands.removeAll { old in
                    old.kind == command.kind || ([EmbeddedCommandKind.play, .pause].contains(old.kind) && [EmbeddedCommandKind.play, .pause].contains(command.kind))
                }
                self.pendingCommands.append(command)
                Task { @MainActor [weak self, weak view] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let view, self.webView === view else { return }
                    self.flushPending(to: view)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        flushPending(to: webView)
    }
    private func flushPending(to view: WKWebView) {
        let pending = pendingCommands; pendingCommands = []
        pending.forEach { apply($0, to: view) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              let body = message.body as? [String: Any], let name = body["kind"] as? String else { return }
        let kind: EmbeddedEventKind
        switch name {
        case "ready": kind = .ready
        case "playing": kind = .playing
        case "paused": kind = .paused
        case "progress": kind = .progress
        case "seeked": kind = .seeked
        case "ended": kind = .ended
        case "failed": kind = .failed
        default: return
        }
        publish(kind: kind, position: (body["position"] as? Double) ?? 0, duration: body["duration"] as? Double)
    }
    private func publish(kind: EmbeddedEventKind, position: Double, duration: Double?) {
        guard let generation, let core, position.isFinite, position >= 0 else { return }
        sequence &+= 1
        let event = EmbeddedPlaybackEvent(generation: generation, sequence: sequence, kind: kind, positionSeconds: position, durationSeconds: duration)
        let previous = eventTask
        eventTask = Task { [weak self, weak core] in
            await previous?.value
            guard let core else { return }
            try? await core.reportEmbeddedPlaybackEvent(event: event)
            await self?.refresh()
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { publish(kind: .failed, position: 0, duration: nil) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView { publish(kind: .failed, position: 0, duration: nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else if navigationAction.targetFrame?.isMainFrame == true,
                  let url = navigationAction.request.url, url.scheme != "about", url.host != "w.soundcloud.com" {
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    nonisolated static func html(url: String, volume: Double) -> String {
        // Encode as JSON rather than interpolating a service link into JavaScript/HTML.
        let data = try! JSONSerialization.data(withJSONObject: [url])
        let encoded = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c")
        let volume = min(1, max(0, volume.isFinite ? volume : 0.5)) * 100
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent}iframe{border:0;width:100%;height:166px}</style></head>
        <body><iframe id="player" allow="autoplay"></iframe><script>
        'use strict';const url=\(encoded)[0];let widget,ready=false,desiredPlay=true,volume=\(volume),duration=null,position=0,lastProgress=0;
        const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position,duration});
        window.durvaldCommand=(kind,value)=>{
          if(kind==='volume'){volume=value*100;if(ready)widget.setVolume(volume);}
          if(kind==='pause'){desiredPlay=false;if(ready)widget.pause();}
          if(kind==='play'){desiredPlay=true;if(ready)widget.play();}
          if(kind==='seek'&&ready){const resume=desiredPlay;widget.seekTo(value*1000);if(resume)widget.play();}
        };
        document.getElementById('player').src='https://w.soundcloud.com/player/?url='+encodeURIComponent(url)+'&auto_play=false&single_active=true';
        const script=document.createElement('script');script.src='https://w.soundcloud.com/player/api.js';script.onerror=()=>send('failed');
        script.onload=()=>{
          widget=SC.Widget(document.getElementById('player'));const E=SC.Widget.Events;
          widget.bind(E.ERROR,()=>send('failed'));
          widget.bind(E.READY,()=>widget.getDuration(d=>{duration=d>0?d/1000:null;ready=true;widget.setVolume(volume);send('ready');if(desiredPlay)widget.play();else widget.isPaused(p=>{if(p)send('paused');});}));
          widget.bind(E.PLAY,()=>{desiredPlay=true;send('playing');});
          widget.bind(E.PAUSE,()=>{desiredPlay=false;send('paused');});
          widget.bind(E.SEEK,e=>{position=e.currentPosition/1000;send('seeked');});
          widget.bind(E.PLAY_PROGRESS,e=>{position=e.currentPosition/1000;if(performance.now()-lastProgress>=500){lastProgress=performance.now();send('progress');}});
          widget.bind(E.FINISH,()=>send('ended'));
        };document.head.append(script);
        </script></body></html>
        """
    }
}

private struct SoundCloudWidgetView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
struct EmbeddedPlayerPanel: View {
    @State private var savingGeneration: String?
    @Environment(DurvaldCoreStore.self) private var store
    var body: some View {
        let player = store.embeddedPlayer
        if let view = player.webView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("SoundCloud · player integrado").font(.caption)
                    if player.status?.state == .loading { ProgressView().controlSize(.small); Text("Carregando…").font(.caption) }
                    Spacer()
                    if let status = player.status, status.trackId == nil {
                        Button("Salvar / associar…") { savingGeneration = status.generation }
                    }
                    Button("Encerrar") { Task { try? await store.core?.stop(); await player.refresh(); await store.refreshPlayback() } }
                }
                SoundCloudWidgetView(webView: view).id(ObjectIdentifier(view)).frame(height: 166)
                    .onDisappear {
                        if player.webView === view {
                            Task { try? await store.core?.stop(); await player.refresh() }
                        }
                    }
                Text("Equalizador, normalização e transições sem intervalo não se aplicam a este player.").font(.caption2).foregroundStyle(.secondary)
            }.padding(8).accessibilityIdentifier("player.soundcloud")
                .sheet(isPresented: Binding(get: { savingGeneration != nil }, set: { if !$0 { savingGeneration = nil } })) {
                    if let generation = savingGeneration { ListeningSourceSaveView(generation: generation) }
                }
        }
        if let notice = player.sourceStatus?.message, player.status != nil || store.playback?.currentTrack != nil { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8) }
        if let status = player.status, let message = status.message {
            HStack { Text(message).font(.caption); Button("Tentar novamente") { Task { await store.togglePause(); await player.refresh() } } }.padding(8)
        }
    }
}
