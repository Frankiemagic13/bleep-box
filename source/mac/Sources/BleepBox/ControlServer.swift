import Foundation
import Network

/// Small HTTP server on 127.0.0.1:28196 for the Stream Deck plugin.
final class ControlServer {
    static let port: UInt16 = 28196
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "bleepbox.http")

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let l = try? NWListener(using: params, on: port) else {
            NSLog("[BleepBox] could not open port \(Self.port)")
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { state in
            if case .failed(let err) = state { NSLog("[BleepBox] server failed: \(err)") }
        }
        l.start(queue: queue)
        listener = l
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let resp = self.respond(to: req)
            c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func respond(to req: String) -> Data {
        let first = req.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return http(404, ["ok": false]) }
        let method = String(parts[0])
        if method == "OPTIONS" { return http(204, nil) }

        let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1]))
        let path = comps?.path ?? "/"
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        var result: (Int, [String: Any]) = (500, ["ok": false])
        DispatchQueue.main.sync {
            result = AppModel.shared.handle(path: path, query: query)
        }
        return http(result.0, result.1)
    }

    private func http(_ code: Int, _ body: [String: Any]?) -> Data {
        let bodyData = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let text = code == 200 ? "OK" : code == 204 ? "No Content" : code == 404 ? "Not Found" : "Error"
        var head = "HTTP/1.1 \(code) \(text)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        head += "Access-Control-Allow-Private-Network: true\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(bodyData.count)\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        return out
    }
}
