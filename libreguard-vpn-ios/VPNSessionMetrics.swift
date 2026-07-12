import Foundation

struct VPNSessionMetrics: Equatable {
    let descriptor: VPNSessionDescriptor
    let traffic: VPNSessionTraffic

    var totalBytes: Int64 {
        traffic.downloadedBytes + traffic.uploadedBytes
    }

    func replacingState(_ state: VPNActivityConnectionState, sampledAt: Date = Date()) -> Self {
        Self(
            descriptor: descriptor,
            traffic: VPNSessionTraffic(
                state: state,
                downloadedBytes: traffic.downloadedBytes,
                uploadedBytes: traffic.uploadedBytes,
                downloadBitsPerSecond: state == .connected ? traffic.downloadBitsPerSecond : 0,
                uploadBitsPerSecond: state == .connected ? traffic.uploadBitsPerSecond : 0,
                sampledAt: sampledAt
            )
        )
    }
}
