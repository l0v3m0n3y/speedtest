import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}


public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}


public enum SpeedTestError: LocalizedError {
    case invalidURL
    case noServersFound
    case badHTTPStatus(Int)
    case unparsableServerList

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noServersFound: return "No available servers found"
        case .badHTTPStatus(let code): return "Server returned HTTP \(code)"
        case .unparsableServerList: return "Could not parse the server list JSON (schema may have changed)"
        }
    }
}


public struct SpeedtestServer {
    public let id: String?
    public let name: String?
    public let country: String?
    public let host: String       // e.g. "example.com:8080"
    public let uploadUrl: String  // full URL, e.g. "http://example.com:8080/speedtest/upload.php"
}


private final class ThroughputDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private(set) var bytesReceived: Int = 0
    private(set) var firstByteTime: Double?
    private(set) var httpStatus: Int?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var buffer = Data()

    func start(_ completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        firstByteTime = Date().timeIntervalSince1970
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytesReceived += data.count
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completion?(.failure(error))
        } else {
            completion?(.success(buffer))
        }
    }
}

public final class SpeedTest {
    private let api = "https://www.speedtest.net/api"

    private var headers: [String: String] = [
        "Accept-Encoding": "gzip, deflate, br",
        "Accept-Language": "en-US,en;q=0.9",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
    ]

    public var debugPrintRawServerJSON = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]
        return URLSession(configuration: config)
    }()

    public init() {}


    private func fetchJSON(
        from urlString: String,
        method: HTTPMethod = .get,
        body: Data? = nil,
        queryParameters: [String: String]? = nil
    ) async throws -> Any {
        var urlComponents = URLComponents(string: urlString)
        if let queryParameters = queryParameters {
            urlComponents?.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = urlComponents?.url else {
            throw SpeedTestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.allHTTPHeaderFields = headers
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SpeedTestError.badHTTPStatus(http.statusCode)
        }

        return try JSONSerialization.jsonObject(with: data)
    }


    public func getServersList(limit: Int = 10) async throws -> Any {
        return try await fetchJSON(from: "\(api)/js/config-sdk?engine=js&limit=\(limit)&https_functional=true")
    }

    public func getDowndetectorOutages(countryCode: String) async throws -> Any {
        return try await fetchJSON(from: "\(api)/downdetector-outages?countryCode=\(countryCode)")
    }

    public func runSpeedTest(limit: Int = 1) async throws -> (download: Double, upload: Double) {
        let rawJSON = try await getServersList(limit: limit)

        if debugPrintRawServerJSON {
            if let data = try? JSONSerialization.data(withJSONObject: rawJSON, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                print("=== RAW SERVER LIST JSON ===\n\(str)\n=============================")
            }
        }

        let servers = parseServers(from: rawJSON)
        guard let bestServer = servers.first else {
            throw SpeedTestError.noServersFound
        }

        let downloadSpeed = try await testDownloadSpeed(server: bestServer)
        let uploadSpeed = try await testUploadSpeed(server: bestServer)

        return (download: downloadSpeed, upload: uploadSpeed)
    }

    private func extractServerArray(from json: Any) -> [[String: Any]]? {
        if let arr = json as? [[String: Any]] {
            return arr
        }
        guard let dict = json as? [String: Any] else { return nil }

        for key in ["servers", "serverList", "networks", "data"] {
            if let arr = dict[key] as? [[String: Any]] {
                return arr
            }
        }

        for outerKey in ["config", "result", "response"] {
            if let inner = dict[outerKey] as? [String: Any] {
                for key in ["servers", "serverList", "networks"] {
                    if let arr = inner[key] as? [[String: Any]] {
                        return arr
                    }
                }
            }
        }
        return nil
    }

    private func parseServers(from json: Any) -> [SpeedtestServer] {
        guard let serverDicts = extractServerArray(from: json) else { return [] }

        return serverDicts.compactMap { server -> SpeedtestServer? in
            let host: String?
            if let h = server["host"] as? String {
                host = h
            } else if let s = server["server"] as? String {
                if let port = server["port"] as? Int {
                    host = "\(s):\(port)"
                } else if let port = server["port"] as? String {
                    host = "\(s):\(port)"
                } else {
                    host = s
                }
            } else {
                host = nil
            }

            let uploadUrl = (server["url"] as? String)
                ?? (server["uploadUrl"] as? String)
                ?? (server["upload_url"] as? String)

            guard let finalHost = host, let finalUploadUrl = uploadUrl else { return nil }

            return SpeedtestServer(
                id: (server["id"] as? String) ?? (server["id"] as? Int).map(String.init),
                name: server["name"] as? String,
                country: server["country"] as? String,
                host: finalHost,
                uploadUrl: finalUploadUrl
            )
        }
    }


    private func testDownloadSpeed(server: SpeedtestServer) async throws -> Double {
        let hostName = server.host.components(separatedBy: ":").first ?? server.host
        let downloadURLString = "https://\(hostName)/download?size=25000000"

        guard let url = URL(string: downloadURLString) else { return 0.0 }

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.get.rawValue
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 30

        let delegate = ThroughputDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        let receivedData: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            delegate.start { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            let task = session.dataTask(with: request)
            task.resume()
        }
        let receivedBytes = receivedData.count

        guard let firstByte = delegate.firstByteTime else {
            throw SpeedTestError.badHTTPStatus(0)
        }
        if let status = delegate.httpStatus, !(200...299).contains(status) {
            throw SpeedTestError.badHTTPStatus(status)
        }
        let startTime = firstByte
        let endTime = Date().timeIntervalSince1970

        let duration = max(endTime - startTime, 0.001)
        let sizeInBits = Double(receivedBytes) * 8.0
        let speedMbps = (sizeInBits / duration) / 1_000_000.0

        return round(speedMbps * 100) / 100
    }


    private func testUploadSpeed(server: SpeedtestServer) async throws -> Double {
        let uploadURLString = server.uploadUrl.replacingOccurrences(of: "http://", with: "https://")
        guard let url = URL(string: uploadURLString) else { return 0.0 }

        let uploadSize = 10 * 1024 * 1024
        let payload = Data(repeating: 0, count: uploadSize)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"upload.bin\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(payload)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.post.rawValue
        request.allHTTPHeaderFields = headers
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let startTime = Date().timeIntervalSince1970
        let (_, response) = try await session.data(for: request)
        let endTime = Date().timeIntervalSince1970

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SpeedTestError.badHTTPStatus(http.statusCode)
        }

        let duration = max(endTime - startTime, 0.001)
        // Use the actual payload size we sent, not counting multipart overhead separately
        // (overhead is negligible relative to 10 MB).
        let sizeInBits = Double(uploadSize) * 8.0
        let speedMbps = (sizeInBits / duration) / 1_000_000.0

        return round(speedMbps * 100) / 100
    }
}
