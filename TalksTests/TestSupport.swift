import XCTest
@testable import Talks

// MARK: - Mock URL Protocol (records every request so tests can assert on what was sent)

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handlers: [Handler] = []
    nonisolated(unsafe) private static var _requests: [(method: String, url: String, body: Data?)] = []

    static func setHandlers(_ handlers: [Handler]) {
        lock.lock()
        _handlers = handlers
        _requests = []
        lock.unlock()
    }

    static var recordedRequests: [(method: String, url: String, body: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    static var remainingHandlerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _handlers.count
    }

    private static func record(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.map(readAll)
        lock.lock()
        _requests.append((request.httpMethod ?? "GET", request.url?.absoluteString ?? "", body))
        lock.unlock()
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func nextHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        guard !_handlers.isEmpty else { return nil }
        return _handlers.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.record(request)
        guard let handler = MockURLProtocol.nextHandler() else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No mock handler registered for \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"]
            ))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Canned Notion response.
func notionResponse(_ status: Int, json: Any, headers: [String: String]? = nil) -> MockURLProtocol.Handler {
    { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (response, data)
    }
}

func notionRawResponse(_ status: Int, body: String) -> MockURLProtocol.Handler {
    { request in
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

// MARK: - Small concurrency helpers

final class ThreadSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

/// Captures PipelineLogger stages while a test runs.
final class LogRecorder: @unchecked Sendable {
    private let box = ThreadSafeBox<[String]>([])

    init() {
        let box = self.box
        PipelineLogger.logListener = { stage, _, details in
            box.update { $0.append(details.isEmpty ? stage : "\(stage) | \(details)") }
        }
    }

    func stop() { PipelineLogger.logListener = nil }

    var entries: [String] { box.get() }

    func contains(_ stage: String) -> Bool {
        entries.contains { $0 == stage || $0.hasPrefix("\(stage) | ") }
    }

    func count(containing text: String) -> Int {
        entries.filter { $0.contains(text) }.count
    }
}

struct FakeStageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Temporary storage

func makeTempDirectory(_ name: String = #function) throws -> URL {
    let safe = name.replacingOccurrences(of: "()", with: "")
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TalksTests-\(safe)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func removeDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@discardableResult
func writeDummyAudio(named name: String, in directory: URL, bytes: Int = 2048) -> URL {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
    return url
}

// MARK: - Fake pipeline stages for JobQueueManager

extension QueueDependencies {
    /// Deterministic, instant stages: transcription and AI succeed, Notion is configured and succeeds.
    static func fake(
        transcript: String = "Fake raw transcript",
        aiAvailable: Bool = true
    ) -> QueueDependencies {
        QueueDependencies(
            transcribe: { _, _ in transcript },
            checkAIAvailability: { (aiAvailable, aiAvailable ? "Available" : "Apple Intelligence is not enabled") },
            structureTranscript: { raw, _, _ in
                ("Formatted: \(raw)", MeetingIntelligence(summary: "Summary"), "Fake Title")
            },
            notionCredentialsConfigured: { true },
            uploadToNotion: { _, onPageCreated in
                onPageCreated("fake-page-id")
                return ("fake-page-id", "https://notion.so/fakepageid")
            }
        )
    }
}

@MainActor
func makeQueue(in directory: URL, dependencies: QueueDependencies = .fake()) -> JobQueueManager {
    JobQueueManager(storageDirectory: directory, dependencies: dependencies, systemIntegration: false)
}
