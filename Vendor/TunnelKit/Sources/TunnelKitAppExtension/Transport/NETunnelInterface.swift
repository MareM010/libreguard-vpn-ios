//
//  NETunnelInterface.swift
//  TunnelKit
//
//  Created by Davide De Rosa on 8/27/17.
//  Copyright (c) 2021 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of TunnelKit.
//
//  TunnelKit is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  TunnelKit is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with TunnelKit.  If not, see <http://www.gnu.org/licenses/>.
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import Foundation
import NetworkExtension
import TunnelKitCore

private let log = PIATunnelKitLogger.logger(for: NETunnelInterface.self)

/// `TunnelInterface` implementation via NetworkExtension.
public class NETunnelInterface: TunnelInterface {
    private weak var impl: NEPacketTunnelFlow?
    private let packetFilter: (Data) -> Bool
    
    public init(impl: NEPacketTunnelFlow, packetFilter: @escaping (Data) -> Bool = { _ in false }) {
        self.impl = impl
        self.packetFilter = packetFilter
    }
    
    // MARK: TunnelInterface
    
    public var isPersistent: Bool {
        return false
    }
    
    // MARK: IOInterface
    
    public func setReadHandler(queue: DispatchQueue, _ handler: @escaping ([Data]?, Error?) -> Void) {
        loopReadPackets(queue, handler)
    }
    
    private func loopReadPackets(_ queue: DispatchQueue, _ handler: @escaping ([Data]?, Error?) -> Void) {

        // WARNING: runs in NEPacketTunnelFlow queue
        impl?.readPackets { [weak self] (packets, protocols) in
            queue.sync {
                guard let self else { return }
                self.loopReadPackets(queue, handler)
                let filteredPackets = packets.filter { packet in
                    !self.packetFilter(packet)
                }
                handler(filteredPackets, nil)
            }
        }
    }
    
    public func writePacket(_ packet: Data, completionHandler: ((Error?) -> Void)?) {
        guard !packetFilter(packet) else {
            completionHandler?(nil)
            return
        }
        let protocolNumber = IPHeader.protocolNumber(inPacket: packet)
        impl?.writePackets([packet], withProtocols: [protocolNumber])
        completionHandler?(nil)
    }
    
    public func writePackets(_ packets: [Data], completionHandler: ((Error?) -> Void)?) {
        let filteredPackets = packets.filter { packet in
            !packetFilter(packet)
        }
        guard !filteredPackets.isEmpty else {
            completionHandler?(nil)
            return
        }
        let protocols = filteredPackets.map {
            IPHeader.protocolNumber(inPacket: $0)
        }
        impl?.writePackets(filteredPackets, withProtocols: protocols)
        completionHandler?(nil)
    }
}
