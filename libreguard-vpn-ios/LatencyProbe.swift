import Foundation
import Network

@MainActor
protocol LatencyProbing: AnyObject {
    func measure(_ servers: [VPNServer]) async -> [Int: Int]
}

@MainActor
final class NetworkLatencyProbe: LatencyProbing {
    func measure(_ servers: [VPNServer]) async -> [Int: Int] {
        var results: [Int: Int] = [:]
        for start in stride(from: 0, to: servers.count, by: 4) {
            let end = min(start + 4, servers.count)
            let batch = Array(servers[start..<end])
            let batchResults = await withTaskGroup(of: (Int, Int?).self) { group in
                for server in batch {
                    let id = server.id
                    let host = server.latencyHost
                    let port = server.latencyPingPort
                    group.addTask { (id, await Self.probe(host: host, portValue: port)) }
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

    nonisolated private static func probe(host: String, portValue: Int) async -> Int? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: portValue)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let completion = ProbeCompletion()
        let started = DispatchTime.now().uptimeNanoseconds

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = "GET /ping HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            if error != nil {
                                completion.finish(nil)
                                connection.cancel()
                                return
                            }
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, error in
                                guard error == nil, data?.isEmpty == false else {
                                    completion.finish(nil)
                                    connection.cancel()
                                    return
                                }
                                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                                completion.finish(Int((Double(elapsed) / 1_000_000).rounded()))
                                connection.cancel()
                            }
                        })
                    case .failed, .cancelled:
                        completion.finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue.global(qos: .utility))
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    completion.finish(nil)
                    connection.cancel()
                }
            }
        } onCancel: {
            completion.finish(nil)
            connection.cancel()
        }
    }
}

private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<Int?, Never>?
    nonisolated(unsafe) private var completedValue: Int??

    nonisolated init() {}

    nonisolated func install(_ continuation: CheckedContinuation<Int?, Never>) {
        lock.lock()
        if let completedValue {
            lock.unlock()
            continuation.resume(returning: completedValue)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    nonisolated func finish(_ value: Int?) {
        lock.lock()
        guard completedValue == nil else {
            lock.unlock()
            return
        }
        completedValue = .some(value)
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
