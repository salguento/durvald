import Foundation
import Network

/// One loopback-only, nonce-scoped page gives the official iframe a real HTTP
/// origin/referrer. It serves no files, media, cookies, API keys or proxy routes.
final class YouTubePageServer {
    private let listener: NWListener
    private let html: Data
    private let path = "/\(UUID().uuidString)"
    private let lock = NSLock()
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    init(html: String) throws {
        self.html = Data(html.utf8)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ completion: @escaping (URL?) -> Void) {
        var delivered = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !delivered else { return }
            switch state {
            case .ready:
                delivered = true
                let url = self.listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)\(self.path)") }
                DispatchQueue.main.async { completion(url) }
            case .failed, .cancelled:
                delivered = true; DispatchQueue.main.async { completion(nil) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.lock.lock()
            let allowed = !self.stopped && self.connections.count < 8
            if allowed { self.connections[id] = connection }
            self.lock.unlock()
            guard allowed else { connection.cancel(); return }
            let queue = DispatchQueue(label: "durvald.youtube.page.connection")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in connection?.cancel(); self?.remove(id) }
            self.receive(connection, id: id, data: Data())
        }
        listener.start(queue: DispatchQueue(label: "durvald.youtube.page"))
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak connection] chunk, _, complete, error in
            guard let self, let connection else { return }
            var request = data; request.append(chunk ?? Data())
            if error != nil || request.count > 16384 { connection.cancel(); self.remove(id); return }
            if request.range(of: Data("\r\n\r\n".utf8)) == nil && !complete { self.receive(connection, id: id, data: request); return }
            let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let valid = line == "GET \(self.path) HTTP/1.1" || line == "GET \(self.path) HTTP/1.0"
            let body = valid ? self.html : Data()
            var response = Data("HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] _ in connection?.cancel(); self?.remove(id) })
        }
    }
    private func remove(_ id: UUID) { lock.lock(); connections.removeValue(forKey: id); lock.unlock() }
    func stop() {
        lock.lock(); stopped = true; let active = Array(connections.values); connections.removeAll(); lock.unlock()
        listener.cancel(); active.forEach { $0.cancel() }
    }
    deinit { stop() }
}
