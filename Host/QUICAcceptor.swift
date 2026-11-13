import Foundation
import Network

/// Accepts incoming QUIC connections (connection groups from a listener's
/// `newConnectionGroupHandler`) and hands each one's primary control stream on, together
/// with the group, so the session can later open the datagram flow or accept a dedicated
/// video stream (`videoStreamAttach`).
///
/// A connection-group client also announces a stream it never uses, and which one turns
/// ready first varies by device (an iPhone's session sat on the unused one). So the
/// primary stream handed on is the first that delivers bytes (the client's `hello`),
/// together with those bytes; a later stream that delivers bytes on the same group can
/// attach as a dedicated video stream once registered by the authenticated session.
/// Shared by `HostServer` and the loopback tests; everything runs on `queue`.
final class QUICAcceptor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let log: @Sendable (String) -> Void
    private let onStream: @Sendable (NWConnection, NWConnectionGroup, Data) -> Void
    private var groups: [ObjectIdentifier: NWConnectionGroup] = [:]
    private var groupsWithStream: Set<ObjectIdentifier> = []
    private var extraStreamHandlers: [ObjectIdentifier: @Sendable (NWConnection, Data) -> Void] = [:]
    static let maxConnections = 32

    init(queue: DispatchQueue,
         log: @escaping @Sendable (String) -> Void,
         onStream: @escaping @Sendable (NWConnection, NWConnectionGroup, Data) -> Void) {
        self.queue = queue
        self.log = log
        self.onStream = onStream
    }

    /// Call on `queue`.
    func accept(_ group: NWConnectionGroup) {
        let peer = Self.describe(group)
        guard groups.count < Self.maxConnections else {
            log("QUIC: connection from \(peer) refused (\(groups.count) open)")
            group.cancel()
            return
        }
        log("QUIC: connection from \(peer)")
        let id = ObjectIdentifier(group)
        groups[id] = group
        group.newConnectionHandler = { [weak self, weak group] stream in
            guard let self, let group else {
                stream.cancel()
                return
            }
            self.watch(stream, of: group, id: id, peer: peer)
        }
        // Clients send no datagrams; set so the group starts like a client group must.
        group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { _, _, _ in }
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.log("QUIC: connection from \(peer) \(state)")
            switch state {
            case .failed, .cancelled:
                self.groups[id] = nil
                self.groupsWithStream.remove(id)
                self.extraStreamHandlers.removeValue(forKey: id)
            default:
                break
            }
        }
        group.start(queue: queue)
    }

    /// Registers a handler for an authenticated client's secondary QUIC stream (`videoStreamAttach`).
    /// Safe to call from any thread; runs `then` on `queue` once registered.
    func registerExtraStreamHandler(for group: NWConnectionGroup,
                                    handler: @escaping @Sendable (NWConnection, Data) -> Void,
                                    then: (@Sendable () -> Void)? = nil) {
        let id = ObjectIdentifier(group)
        queue.async {
            if self.groups[id] != nil {
                self.extraStreamHandlers[id] = handler
            }
            then?()
        }
    }

    func unregisterExtraStreamHandler(for group: NWConnectionGroup) {
        let id = ObjectIdentifier(group)
        queue.async {
            self.extraStreamHandlers.removeValue(forKey: id)
        }
    }

    private func watch(_ stream: NWConnection, of group: NWConnectionGroup, id: ObjectIdentifier, peer: String) {
        log("QUIC: stream from \(peer) announced")
        stream.stateUpdateHandler = { [weak self, weak group] state in
            guard let self else { return }
            self.log("QUIC: stream from \(peer) \(state)")
            guard case .ready = state else { return }
            stream.stateUpdateHandler = nil
            stream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak group] data, _, _, _ in
                guard let self else { return }
                guard let data, !data.isEmpty, let group, self.groups[id] != nil else {
                    self.log("QUIC: extra stream from \(peer) closed")
                    stream.cancel()
                    return
                }
                if !self.groupsWithStream.contains(id) {
                    self.groupsWithStream.insert(id)
                    self.log("QUIC: stream from \(peer) handed to a session")
                    self.onStream(stream, group, data)
                } else if let handler = self.extraStreamHandlers.removeValue(forKey: id) {
                    self.log("QUIC: dedicated video stream from \(peer) attached")
                    handler(stream, data)
                } else {
                    self.log("QUIC: extra stream from \(peer) closed")
                    stream.cancel()
                }
            }
        }
        stream.start(queue: queue)
    }

    func cancelAll() {
        queue.async {
            for group in self.groups.values { group.cancel() }
            self.groups.removeAll()
            self.groupsWithStream.removeAll()
            self.extraStreamHandlers.removeAll()
        }
    }

    private static func describe(_ group: NWConnectionGroup) -> String {
        if let members = (group.descriptor as? NWMultiplexGroup)?.members, let first = members.first {
            if case .hostPort(let host, let port) = first { return "\(host):\(port)" }
            return "\(first)"
        }
        return "unknown"
    }
}
