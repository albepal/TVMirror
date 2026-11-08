import Foundation
import Network
import os

let statsLog = Logger(subsystem: "com.albertopalazzolo.tvmirror", category: "stats")

/// TCP link to the TV. Video is flow-controlled by acks from the TV: when too many frames are
/// unacknowledged (Wi-Fi hiccup), frames are dropped and a fresh keyframe is requested instead of
/// letting a backlog build up, so delay never grows.
final class StreamConnection {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "tvmirror.net", qos: .userInteractive)

    // All below accessed only on `queue`.
    private var ready = false
    private var finished = false
    private var unacked = 0
    private var needKeyframe = false
    private var lastKeyRequest = DispatchTime(uptimeNanoseconds: 0)
    // Stats (queue only): send time per frame pts → round-trip time when the TV acks it.
    private var sentAt: [UInt64: UInt64] = [:]
    private var rttSum: UInt64 = 0, rttMax: UInt64 = 0, rttCount = 0, dropped = 0
    private var lastStats = DispatchTime.now().uptimeNanoseconds

    /// Frames in flight before we start dropping. 8 frames ≈ 130 ms at 60 fps.
    private let maxUnacked = 8

    var onReady: (() -> Void)?
    var onKeyframeRequest: (() -> Void)?
    /// Called once, on the main queue. nil = clean stop.
    var onClosed: ((String?) -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        conn = NWConnection(to: endpoint, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.receiveHeader()
                self.onReady?()
            case .failed(let error):
                self.finish(self.ready ? "Connection lost (\(error.localizedDescription))"
                                       : "Couldn't reach the TV (\(error.localizedDescription)).")
            case .cancelled:
                self.finish(nil)
            default:
                break // .waiting is handled by the session's connect timeout
            }
        }
        conn.start(queue: queue)
    }

    func close(sayBye: Bool) {
        queue.async { [self] in
            guard !finished else { return }
            if ready && sayBye {
                conn.send(content: makePacket(.bye), completion: .contentProcessed { [weak self] _ in
                    self?.conn.cancel()
                })
            } else {
                conn.cancel()
            }
        }
    }

    func sendHello(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        queue.async { [self] in write(makePacket(.hello, payload: data)) }
    }

    /// `config` is non-nil on keyframes; it is sent together with the frame so dropping never separates them.
    func sendVideo(frame: Data, config: Data?, keyframe: Bool, pts: UInt64) {
        queue.async { [self] in
            guard ready, !finished else { return }
            if unacked >= maxUnacked {
                dropped += 1
                needKeyframe = true
                requestKeyframe()
                return
            }
            if needKeyframe {
                guard keyframe else { requestKeyframe(); return }
                needKeyframe = false
            }
            if let config { write(makePacket(.videoConfig, payload: config)) }
            write(makePacket(.videoFrame, flags: keyframe ? PacketFlags.keyframe : 0, pts: pts, payload: frame))
            sentAt[pts] = DispatchTime.now().uptimeNanoseconds
            unacked += 1
        }
    }

    func sendAudio(_ pcm: Data, pts: UInt64) {
        queue.async { [self] in
            guard ready, !finished, unacked < maxUnacked * 2 else { return }
            write(makePacket(.audio, pts: pts, payload: pcm))
        }
    }

    // MARK: - Private (on queue)

    private func write(_ packet: Data) {
        guard !finished else { return }
        conn.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("Connection lost (\(error.localizedDescription))") }
        })
    }

    private func requestKeyframe() {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds > lastKeyRequest.uptimeNanoseconds + 250_000_000 else { return }
        lastKeyRequest = now
        onKeyframeRequest?()
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        conn.cancel()
        let callback = onClosed
        DispatchQueue.main.async { callback?(error) }
    }

    private func receiveHeader() {
        conn.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == headerSize else {
                if isComplete || error != nil { self.finish(self.finished ? nil : "The TV closed the connection.") }
                return
            }
            let bytes = [UInt8](data)
            let pts = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let length = Int(bytes[10]) << 24 | Int(bytes[11]) << 16 | Int(bytes[12]) << 8 | Int(bytes[13])
            if length > 0 {
                self.conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] _, _, _, error in
                    guard let self else { return }
                    if error != nil { self.finish("Connection lost."); return }
                    self.handle(type: bytes[0], pts: pts)
                    self.receiveHeader()
                }
            } else {
                self.handle(type: bytes[0], pts: pts)
                if !self.finished { self.receiveHeader() }
            }
        }
    }

    private func handle(type: UInt8, pts: UInt64) {
        switch PacketType(rawValue: type) {
        case .ack:
            unacked = max(0, unacked - 1)
            let now = DispatchTime.now().uptimeNanoseconds
            if let sent = sentAt.removeValue(forKey: pts) {
                let rtt = now - sent
                rttSum += rtt; rttMax = max(rttMax, rtt); rttCount += 1
            }
            if now - lastStats > 2_000_000_000, rttCount > 0 {
                statsLog.notice("net: ack rtt avg \(Double(self.rttSum) / Double(self.rttCount) / 1e6, format: .fixed(precision: 1)) ms max \(Double(self.rttMax) / 1e6, format: .fixed(precision: 1)) ms, \(self.rttCount) frames, \(self.dropped) dropped")
                rttSum = 0; rttMax = 0; rttCount = 0; dropped = 0; lastStats = now
                if sentAt.count > 500 { sentAt.removeAll() }
            }
        case .requestKeyframe: onKeyframeRequest?()
        case .bye: finish(nil) // stopped from the TV: a normal end, not an error
        default: break
        }
    }
}
