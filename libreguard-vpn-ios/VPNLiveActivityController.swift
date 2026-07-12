import ActivityKit
import Foundation

@MainActor
protocol VPNLiveActivityControlling: AnyObject {
    func start(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async
    func update(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async
    func end(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async
    func endAll() async
}

@MainActor
final class VPNLiveActivityController: VPNLiveActivityControlling {
    func start(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        for activity in Activity<VPNActivityAttributes>.activities
        where activity.attributes.sessionID != descriptor.sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if Activity<VPNActivityAttributes>.activities.contains(where: {
            $0.attributes.sessionID == descriptor.sessionID
        }) {
            await update(descriptor: descriptor, traffic: traffic)
            return
        }

        let attributes = VPNActivityAttributes(
            sessionID: descriptor.sessionID,
            serverName: descriptor.serverName,
            countryFlag: descriptor.countryFlag,
            protocolName: descriptor.protocolName,
            connectedAt: descriptor.connectedAt
        )
        let content = ActivityContent(
            state: VPNActivityAttributes.ContentState(traffic: traffic),
            staleDate: traffic.sampledAt.addingTimeInterval(15),
            relevanceScore: 100
        )
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func update(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async {
        guard let activity = Activity<VPNActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == descriptor.sessionID
        }) else { return }
        await activity.update(ActivityContent(
            state: VPNActivityAttributes.ContentState(traffic: traffic),
            staleDate: traffic.sampledAt.addingTimeInterval(15),
            relevanceScore: traffic.state == .reconnecting ? 110 : 100
        ))
    }

    func end(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async {
        guard let activity = Activity<VPNActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == descriptor.sessionID
        }) else { return }
        await activity.end(
            ActivityContent(
                state: VPNActivityAttributes.ContentState(traffic: traffic),
                staleDate: nil,
                relevanceScore: 0
            ),
            dismissalPolicy: .immediate
        )
    }

    func endAll() async {
        for activity in Activity<VPNActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

@MainActor
final class NoOpVPNLiveActivityController: VPNLiveActivityControlling {
    func start(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async {}
    func update(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async {}
    func end(descriptor: VPNSessionDescriptor, traffic: VPNSessionTraffic) async {}
    func endAll() async {}
}
