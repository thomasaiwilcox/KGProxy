import Vapor
import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import KGKit
import KGKitKuzu

// MARK: - Models

struct ChatMessage: Content {
    var role: String
    var content: String
}

struct ChatCompletionRequest: Content {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double?
    var top_p: Double?
    var max_tokens: Int?
    var stream: Bool?
    // Forward-compat: Allow unknown fields without failing
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.messages = (try? c.decode([ChatMessage].self, forKey: .messages)) ?? []
        self.temperature = try? c.decode(Double.self, forKey: .temperature)
        self.top_p = try? c.decode(Double.self, forKey: .top_p)
        self.max_tokens = try? c.decode(Int.self, forKey: .max_tokens)
        self.stream = try? c.decode(Bool.self, forKey: .stream)
    }
    init(model: String, messages: [ChatMessage], temperature: Double? = nil, top_p: Double? = nil, max_tokens: Int? = nil, stream: Bool? = nil) {
        self.model = model; self.messages = messages
        self.temperature = temperature; self.top_p = top_p
        self.max_tokens = max_tokens; self.stream = stream
    }
}

struct OpenAIProxyConfig {
    let baseURL: String
    let apiKey: String?
}

struct KGConfig {
    let mode: String        // "conscious" | "auto" | "combined"
    let userID: String
    let namespace: String
    let contextLimit: Int
    let consent: Bool
}

enum DriverChoice: String {
    case kuzu, sqlite, memory
}

// MARK: - Engine setup

func makeEngine(for namespace: String) throws -> KGEngine {
    let driverChoice = DriverChoice(rawValue: (Environment.get("KG_DRIVER") ?? "kuzu").lowercased()) ?? .kuzu
    switch driverChoice {
    case .kuzu:
        let dir = Environment.get("KG_DB_DIR") ?? "./data"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbURL = URL(fileURLWithPath: "\(dir)/\(namespace).kuzu")
        return KGEngine(driver: KuzuDriver(databaseURL: dbURL))
    case .sqlite:
        let dir = Environment.get("KG_DB_DIR") ?? "./data"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbURL = URL(fileURLWithPath: "\(dir)/\(namespace).sqlite")
        return KGEngine(driver: SQLiteDriver(databaseURL: dbURL))
    case .memory:
        return KGEngine(driver: MemoryDriver())
    }
}

func extractKGConfig(_ req: Request) -> KGConfig {
    KGConfig(
        mode: req.headers.first(name: "X-KG-Mode") ?? "combined",
        userID: req.headers.first(name: "X-KG-User-ID") ?? "anonymous",
        namespace: req.headers.first(name: "X-KG-Namespace") ?? "default",
        contextLimit: Int(req.headers.first(name: "X-KG-Context-Limit") ?? "5") ?? 5,
        consent: (req.headers.first(name: "X-KG-Consent") ?? "false").lowercased() == "true"
    )
}

func extractOpenAIConfig() -> OpenAIProxyConfig {
    OpenAIProxyConfig(
        baseURL: Environment.get("OPENAI_BASE_URL") ?? "https://api.openai.com",
        apiKey: Environment.get("OPENAI_API_KEY")
    )
}

// MARK: - SSE parsing (to reconstruct assistant content)

struct ChatCompletionChunkChoiceDelta: Decodable {
    var content: String?
}

struct ChatCompletionChunkChoice: Decodable {
    var delta: ChatCompletionChunkChoiceDelta
}

struct ChatCompletionChunk: Decodable {
    var choices: [ChatCompletionChunkChoice]
}

final class SSEAccumulator {
    private var buffer = ""
    private(set) var assistantText = ""

    func append(_ bytes: ByteBuffer) {
        var copy = bytes
        if let str = copy.readString(length: copy.readableBytes) {
            buffer += str
            processBuffer()
        }
    }

    private func processBuffer() {
        // Process by lines; SSE lines separated by \n (CRLF tolerated)
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[range.upperBound...])
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" && !payload.isEmpty else { return }
        if let data = payload.data(using: .utf8),
           let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data) {
            for c in chunk.choices {
                if let piece = c.delta.content {
                    assistantText += piece
                }
            }
        }
    }
}

// MARK: - Streaming Delegate

final class PassthroughDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    private let writer: Response.Body.StreamWriter
    private let accumulator: SSEAccumulator?
    private let eventLoop: EventLoop
    private let setHeaders: (HTTPHeaders) -> Void

    init(writer: @escaping Response.Body.StreamWriter,
         accumulator: SSEAccumulator?,
         eventLoop: EventLoop,
         setHeaders: @escaping (HTTPHeaders) -> Void) {
        self.writer = writer
        self.accumulator = accumulator
        self.eventLoop = eventLoop
        self.setHeaders = setHeaders
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        // Propagate important headers to client (content-type, transfer-encoding, cache-control, x-request-id)
        setHeaders(head.headers)
        return eventLoop.makeSucceededVoidFuture()
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        // Tee: accumulate to reconstruct assistant text (when streaming)
        accumulator?.append(buffer)
        return writer(.buffer(buffer))
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        _ = writer(.end)
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
        // Best-effort termination
        _ = writer(.end)
    }
}

// MARK: - Routes

func bootRoutes(_ app: Application) throws {
    // Add CORS middleware for browser clients
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept,
            .authorization,
            .contentType,
            .origin,
            .xRequestedWith,
            .userAgent,
            .accessControlAllowOrigin,
            .name("X-KG-Consent"),
            .name("X-KG-User-ID"),
            .name("X-KG-Namespace"),
            .name("X-KG-Mode"),
            .name("X-KG-Context-Limit")
        ]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(cors)

    // Enhanced health endpoints with JSON responses
    app.get("health") { req async throws -> [String: Any] in
        let upstream = extractOpenAIConfig()
        let driverChoice = DriverChoice(rawValue: (Environment.get("KG_DRIVER") ?? "kuzu").lowercased()) ?? .kuzu
        return [
            "status": "ok",
            "driver": driverChoice.rawValue,
            "upstream_base_url": upstream.baseURL,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
    
    app.on(.HEAD, "health") { req async throws -> Response in
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        return response
    }
    
    app.get("ready") { req async throws -> [String: Any] in
        let upstream = extractOpenAIConfig()
        let driverChoice = DriverChoice(rawValue: (Environment.get("KG_DRIVER") ?? "kuzu").lowercased()) ?? .kuzu
        
        // Test KG engine initialization
        do {
            let _ = try makeEngine(for: "readiness-check")
            return [
                "status": "ready",
                "driver": driverChoice.rawValue,
                "upstream_base_url": upstream.baseURL,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        } catch {
            throw Abort(.serviceUnavailable, reason: "KG engine initialization failed: \(error.localizedDescription)")
        }
    }

    // OpenAI-compatible chat completions (supports streaming and non-streaming)
    app.post("v1", "chat", "completions") { req async throws -> Response in
        let kg = extractKGConfig(req)
        guard kg.consent else { throw Abort(.forbidden, reason: "KG memory requires consent") }
        let engine = try makeEngine(for: kg.namespace)
        let upstream = extractOpenAIConfig()

        var body = try req.content.decode(ChatCompletionRequest.self)

        // Auto/combined: Retrieve relevant context and prepend a system message
        if kg.mode == "auto" || kg.mode == "combined" {
            if let last = body.messages.last?.content {
                let hits = try await engine.search(.init(text: last, k: kg.contextLimit))
                let snippet = hits.compactMap { $0.snippet }.joined(separator: "\n")
                if !snippet.isEmpty {
                    let sys = ChatMessage(role: "system", content: "Relevant context:\n\(snippet)")
                    body.messages.insert(sys, at: 0)
                }
            }
        }

        // Build OpenAI request JSON
        struct AnyEncodable: Encodable {
            let encodeFunc: (Encoder) throws -> Void
            func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
            init<T: Encodable>(_ wrapped: T) { self.encodeFunc = wrapped.encode(to:) }
        }

        var jsonDict: [String: AnyEncodable] = [
            "model": AnyEncodable(body.model),
            "messages": AnyEncodable(body.messages),
        ]
        if let t = body.temperature { jsonDict["temperature"] = AnyEncodable(t) }
        if let p = body.top_p { jsonDict["top_p"] = AnyEncodable(p) }
        if let m = body.max_tokens { jsonDict["max_tokens"] = AnyEncodable(m) }
        if let s = body.stream { jsonDict["stream"] = AnyEncodable(s) }

        let json = try JSONEncoder().encode(DictionaryEncoder(jsonDict))

        // Authorization: prefer client’s header, else env OPENAI_API_KEY
        let authHeader = req.headers.first(name: .authorization)
        let bearer = authHeader ?? (upstream.apiKey.map { "Bearer \($0)" } ?? "")

        // Non-streaming path
        if body.stream != true {
            let client = req.application.http.client.shared
            let request = try HTTPClient.Request(
                url: "\(upstream.baseURL)/v1/chat/completions",
                method: .POST,
                headers: HTTPHeaders([
                    ("Content-Type", "application/json"),
                ] + (bearer.isEmpty ? [] : [("Authorization", bearer)])),
                body: .data(json)
            )
            let result = try await client.execute(request: request, timeout: .seconds(120)).get()

            // Extract assistant text for ingestion
            var assistantText = ""
            if var buf = result.body, let data = buf.readData(length: buf.readableBytes) {
                if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = parsed["choices"] as? [[String: Any]],
                   let message = choices.first?["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    assistantText = content
                }
                // Return passthrough with upstream status and headers
                var resp = Response(status: HTTPResponseStatus(statusCode: Int(result.status.code)))
                resp.headers.replaceOrAdd(name: .contentType, value: "application/json")
                
                // Propagate selected headers from upstream
                if let cc = result.headers.first(name: "cache-control") {
                    resp.headers.replaceOrAdd(name: "cache-control", value: cc)
                }
                if let rid = result.headers.first(name: "x-request-id") {
                    resp.headers.replaceOrAdd(name: "x-request-id", value: rid)
                }
                
                resp.body = .init(data: data)
                // Ingest asynchronously
                ingestEpisodes(engine: engine, kg: kg, request: body.messages, assistant: assistantText)
                return resp
            } else {
                throw Abort(.badGateway, reason: "Empty upstream response")
            }
        }

        // Streaming path (SSE)
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-cache")
        response.headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        response.body = .stream { writer in
            let client = req.application.http.client.shared
            let accumulator = SSEAccumulator()

            // Prepare request
            let request: HTTPClient.Request
            do {
                request = try HTTPClient.Request(
                    url: "\(upstream.baseURL)/v1/chat/completions",
                    method: .POST,
                    headers: HTTPHeaders([
                        ("Content-Type", "application/json"),
                    ] + (bearer.isEmpty ? [] : [("Authorization", bearer)])),
                    body: .data(json)
                )
            } catch {
                _ = writer(.end)
                return
            }

            // Delegate will stream upstream chunks to client writer and tee for ingestion
            let delegate = PassthroughDelegate(
                writer: writer,
                accumulator: accumulator,
                eventLoop: req.eventLoop
            ) { headHeaders in
                // Propagate important headers from upstream
                if let ct = headHeaders.first(name: "content-type") {
                    response.headers.replaceOrAdd(name: .contentType, value: ct)
                }
                if let cc = headHeaders.first(name: "cache-control") {
                    response.headers.replaceOrAdd(name: "cache-control", value: cc)
                }
                if let te = headHeaders.first(name: "transfer-encoding") {
                    response.headers.replaceOrAdd(name: "transfer-encoding", value: te)
                }
                if let rid = headHeaders.first(name: "x-request-id") {
                    response.headers.replaceOrAdd(name: "x-request-id", value: rid)
                }
            }

            // Execute streaming request
            client.execute(request: request, delegate: delegate).whenComplete { result in
                switch result {
                case .success:
                    // Ingest user prompt and reconstructed assistant text (best-effort)
                    ingestEpisodes(engine: engine, kg: kg, request: body.messages, assistant: accumulator.assistantText)
                case .failure:
                    break
                }
            }
        }
        return response
    }

    // Memory utility endpoints
    app.get("v1", "memory", "context") { req async throws -> [String: Any] in
        let kg = extractKGConfig(req)
        let engine = try makeEngine(for: kg.namespace)
        let q = try req.query.get(String.self, at: "q")
        let hits = try await engine.search(.init(text: q, k: kg.contextLimit))
        return [
            "query": q,
            "hits": hits.map { ["id": $0.id, "score": $0.score, "snippet": $0.snippet ?? ""] }
        ]
    }

    app.post("v1", "memory", "ingest") { req async throws -> [String: String] in
        let kg = extractKGConfig(req)
        let engine = try makeEngine(for: kg.namespace)
        struct IngestBody: Content { let text: String }
        let input = try req.content.decode(IngestBody.self)
        let now = Date()
        let ep = Episode(id: .init(raw: "ep:free:\(UUID().uuidString)"),
                         text: input.text,
                         json: nil,
                         eventTime: now,
                         ingestTime: now,
                         groupID: kg.userID)
        try await engine.ingest(episode: ep)
        return ["status": "ok"]
    }
}

// Helper to encode heterogenous JSON dict
private struct DictionaryEncoder: Encodable {
    let dict: [String: any Encodable]
    init(_ d: [String: any Encodable]) { self.dict = d }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKeys.self)
        for (k, v) in dict {
            try c.encode(AnyCodable(v), forKey: .key(k))
        }
    }
}

private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?
    static func key(_ s: String) -> Self { .init(stringValue: s)! }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}

private struct AnyCodable: Encodable {
    let enc: (Encoder) throws -> Void
    init(_ value: any Encodable) { self.enc = value.encode(to:) }
    func encode(to encoder: Encoder) throws { try enc(encoder) }
}

// MARK: - Ingestion

private func ingestEpisodes(engine: KGEngine, kg: KGConfig, request messages: [ChatMessage], assistant: String) {
    let now = Date()
    let promptConcat = messages.map { "[\($0.role)] \($0.content)" }.joined(separator: "\n---\n")
    let epUser = Episode(
        id: .init(raw: "ep:req:\(UUID().uuidString)"),
        text: promptConcat,
        json: nil,
        eventTime: now,
        ingestTime: now,
        groupID: kg.userID
    )
    let epAssistant = Episode(
        id: .init(raw: "ep:resp:\(UUID().uuidString)"),
        text: assistant,
        json: nil,
        eventTime: now,
        ingestTime: now,
        groupID: kg.userID
    )
    Task.detached {
        try? await engine.ingest(episode: epUser)
        try? await engine.ingest(episode: epAssistant)
        // TODO: Run adapters for entity/fact extraction; apply batching and conflict rules
    }
}

// MARK: - Main

@main
struct Main {
    static func main() throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = Application(env)
        defer { app.shutdown() }
        try bootRoutes(app)
        try app.run()
    }
}