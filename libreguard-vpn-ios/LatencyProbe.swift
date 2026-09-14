import Foundation
import OSLog

@MainActor
protocol LatencyProbing: AnyObject {
    func measure(_ servers: [VPNServer]) async -> [Int: Int]
}

@MainActor
final class NetworkLatencyProbe: LatencyProbing {
    private static let maximumConcurrentProbes = 8
    private let urlSession: URLSession
    private let timeoutInterval: TimeInterval
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.libreguard.libreguard-vpn-ios",
        category: "LatencyProbe"
    )

    init(urlSession: URLSession = .shared, timeoutInterval: TimeInterval = 3) {
        self.urlSession = urlSession
        self.timeoutInterval = max(timeoutInterval, 0.1)
    }

    func measure(_ servers: [VPNServer]) async -> [Int: Int] {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let targets = servers.map {
            ProbeTarget(id: $0.id, host: $0.latencyHost, portValue: $0.latencyPingPort)
        }
        guard !targets.isEmpty else {
            logger.debug("Latency measurement skipped; serverCount=0")
            return [:]
        }

        let queue = ProbeWorkQueue(targets: targets)
        let session = urlSession
        let timeoutInterval = timeoutInterval
        let workerCount = min(Self.maximumConcurrentProbes, targets.count)
        logger.debug(
            "Latency measurement started; serverCount=\(servers.count, privacy: .public), workerCount=\(workerCount, privacy: .public)"
        )

        let values = await withTaskGroup(of: [(Int, Int?)].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var workerValues: [(Int, Int?)] = []

                    while !Task.isCancelled {
                        guard let target = await queue.next() else { break }
                        let latency = await Self.warmAndMeasure(
                            host: target.host,
                            portValue: target.portValue,
                            urlSession: session,
                            timeoutInterval: timeoutInterval
                        )
                        workerValues.append((target.id, latency))
                    }

                    return workerValues
                }
            }

            var workerValues: [(Int, Int?)] = []
            for await values in group {
                workerValues.append(contentsOf: values)
            }
            return workerValues
        }

        var results: [Int: Int] = [:]
        for (id, latency) in values {
            if let latency { results[id] = latency }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        logger.debug(
            "Latency measurement finished; serverCount=\(servers.count, privacy: .public), attemptedCount=\(values.count, privacy: .public), successCount=\(results.count, privacy: .public), workerCount=\(workerCount, privacy: .public), elapsedMs=\(Int((Double(elapsed) / 1_000_000).rounded()), privacy: .public), cancelled=\(Task.isCancelled, privacy: .public)"
        )
        return results
    }

    nonisolated private static func warmAndMeasure(
        host: String,
        portValue: Int,
        urlSession: URLSession,
        timeoutInterval: TimeInterval
    ) async -> Int? {
        guard await warmUp(
            host: host,
            portValue: portValue,
            urlSession: urlSession,
            timeoutInterval: timeoutInterval
        ) else {
            return nil
        }

        return await probe(
            host: host,
            portValue: portValue,
            urlSession: urlSession,
            timeoutInterval: timeoutInterval
        )
    }

    nonisolated private static func warmUp(
        host: String,
        portValue: Int,
        urlSession: URLSession,
        timeoutInterval: TimeInterval
    ) async -> Bool {
        guard let url = pingURL(host: host, portValue: portValue) else { return false }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval

        do {
            let (data, response) = try await urlSession.data(for: request)
            return isValidPongResponse(response: response, data: data)
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    nonisolated private static func probe(
        host: String,
        portValue: Int,
        urlSession: URLSession,
        timeoutInterval: TimeInterval
    ) async -> Int? {
        guard let url = pingURL(host: host, portValue: portValue) else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard isValidPongResponse(response: response, data: data) else {
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

    nonisolated private static func isValidPongResponse(response: URLResponse?, data: Data) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return false
        }
        return hasValidPong(in: data)
    }
}

private struct ProbeTarget: Sendable {
    let id: Int
    let host: String
    let portValue: Int
}

private actor ProbeWorkQueue {
    private let targets: [ProbeTarget]
    private var nextIndex = 0

    init(targets: [ProbeTarget]) {
        self.targets = targets
    }

    func next() -> ProbeTarget? {
        guard nextIndex < targets.count else { return nil }
        defer { nextIndex += 1 }
        return targets[nextIndex]
    }
}
