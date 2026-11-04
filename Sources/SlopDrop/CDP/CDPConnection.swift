import Foundation

struct CDPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A minimal Chrome DevTools Protocol client: one WebSocket, request/response
/// correlation by id. Events are ignored — SlopDrop drives, it never listens,
/// so it subscribes to none beyond Page (Runtime's would stream every
/// console line in Slack).
actor CDPConnection {
    private let url: URL
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var isClosed = false

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    func open() async throws {
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        reader = Task { [weak self] in await self?.readLoop() }
        _ = try await send("Page.enable")
    }

    /// False once the socket has dropped; the bridge then opens a new one.
    var isOpen: Bool { !isClosed }

    func close() {
        isClosed = true
        reader?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        failPending(CDPError(message: "connection closed"))
    }

    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let socket, !isClosed else { throw CDPError(message: "socket closed") }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { await self?.fail(id: id, error: error) }
            }
        }
    }

    /// Evaluates JS in the page and returns the JSON value.
    func evaluate(_ expression: String) async throws -> Any? {
        let result = try await send("Runtime.evaluate", [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let text = details["text"] as? String ?? "JavaScript exception"
            let exception = (details["exception"] as? [String: Any])?["description"] as? String
            throw CDPError(message: exception ?? text)
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Evaluates JS and decodes the returned JSON string into a value.
    func evaluateJSON(_ expression: String) async throws -> Any? {
        guard let raw = try await evaluate("JSON.stringify(\(expression))") as? String,
              let data = raw.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Fetches a URL through the page's own network stack. Slack makes the
    /// request, so SlopDrop itself never talks to anything but 127.0.0.1, and
    /// CORS doesn't apply.
    func loadResource(_ url: String) async throws -> Data {
        let tree = try await send("Page.getFrameTree")
        guard let frameID = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String else {
            throw CDPError(message: "no frame")
        }
        let loaded = try await send("Network.loadNetworkResource", [
            "frameId": frameID,
            "url": url,
            "options": ["disableCache": false, "includeCredentials": false],
        ])
        guard let resource = loaded["resource"] as? [String: Any],
              resource["success"] as? Bool == true,
              let stream = resource["stream"] as? String
        else { throw CDPError(message: "load failed") }

        var data = Data()
        defer { Task { _ = try? await self.send("IO.close", ["handle": stream]) } }
        for _ in 0..<64 {
            let chunk = try await send("IO.read", ["handle": stream, "size": 262_144])
            let text = chunk["data"] as? String ?? ""
            if chunk["base64Encoded"] as? Bool == true {
                data.append(Data(base64Encoded: text) ?? Data())
            } else {
                data.append(Data(text.utf8))
            }
            if chunk["eof"] as? Bool == true { break }
            if data.count > 2_000_000 { throw CDPError(message: "resource too large") }
        }
        return data
    }

    private func readLoop() async {
        guard let socket else { return }
        while !isClosed {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                break
            }
            guard case .string(let text) = message else { continue }
            // A message that won't parse is that message's problem, never the
            // socket's: drop it, and fail its request so nothing waits forever.
            guard let object = Self.decode(text) else {
                if let id = Self.responseID(text) { fail(id: id, error: CDPError(message: "unreadable response")) }
                continue
            }
            guard let id = object["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else { continue }

            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: CDPError(message: error["message"] as? String ?? "CDP error"))
            } else {
                continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
        }
        isClosed = true
        failPending(CDPError(message: "socket closed"))
    }

    /// Chrome writes half of a surrogate pair (text cut mid-emoji) as a lone
    /// `\ud83d`, which JSONSerialization rejects; those become U+FFFD.
    private static let loneSurrogate = try! NSRegularExpression(
        pattern: #"\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}"#
    )

    static func decode(_ text: String) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return object }
        let repaired = loneSurrogate.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: #"\\ufffd"#
        )
        return try? JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
    }

    private static let leadingID = try! NSRegularExpression(pattern: #"^\{"id":(\d+)"#)

    /// The id of a response too broken to parse; Chrome always writes it first.
    static func responseID(_ text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = leadingID.firstMatch(in: text, range: range),
              let digits = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[digits])
    }

    private func fail(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
