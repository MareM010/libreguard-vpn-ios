import Foundation

@MainActor
protocol LatencyProbing: AnyObject {
    func measure(_ servers: [VPNServer]) async -> [Int: Int]
}

@MainActor
final class NetworkLatencyProbe: LatencyProbing {
    private let urlSession: URLSession
    private let timeoutInterval: TimeInterval

    init(urlSession: URLSession = .shared, timeoutInterval: TimeInterval = 3) {
        self.urlSession = urlSession
        self.timeoutInterval = max(timeoutInterval, 0.1)
    }

    func measure(_ servers: [VPNServer]) async -> [Int: Int] {
        var results: [Int: Int] = [:]
        let session = urlSession
        let timeoutInterval = timeoutInterval

        for start in stride(from: 0, to: servers.count, by: 4) {
            let end = min(start + 4, servers.count)
            let batch = Array(servers[start..<end])
            let batchResults = await withTaskGroup(of: (Int, Int?).self) { group in
                for server in batch {
                    let id = server.id
                    let host = server.latencyHost
                    let port = server.latencyPingPort
                    group.addTask {
                        (
                            id,
                            await Self.probe(
                                host: host,
                                portValue: port,
                                urlSession: session,
                                timeoutInterval: timeoutInterval
                            )
                        )
                    }
                }
                var values: [(Int, Int?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (id, latency) in batchResults {
                if let latency { results[id] = latency }
            }
            if Task.isCancelled { break }
        }
        return results
    }

    nonisolated private static func probe(
        host: String,
        portValue: Int,
        urlSession: URLSession,
        timeoutInterval: TimeInterval
    ) async -> Int? {
        guard let url = pingURL(host: host, portValue: portValue) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  hasValidPong(in: data) else {
                return nil
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            return Int((Double(elapsed) / 1_000_000).rounded())
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    nonisolated private static func pingURL(host: String, portValue: Int) -> URL? {
        guard !host.isEmpty, (1...65_535).contains(portValue) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = portValue
        components.path = "/ping"
        return components.url
    }

    nonisolated private static func hasValidPong(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["pong"] as? Bool == true
    }
}
