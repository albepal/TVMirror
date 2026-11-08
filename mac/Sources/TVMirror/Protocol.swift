import Foundation

/// Wire format shared with the TV app (see tv/.../Packet.java).
/// Every packet: type (1 byte) | flags (1 byte) | pts in µs (8 bytes, big endian) | length (4 bytes, big endian) | payload.
enum PacketType: UInt8 {
    case hello = 0          // Mac → TV, JSON describing the stream
    case videoConfig = 1    // Mac → TV, codec parameter sets (Annex B), sent before every keyframe
    case videoFrame = 2     // Mac → TV, one encoded frame (Annex B)
    case audio = 3          // Mac → TV, PCM s16le interleaved
    case bye = 4            // either way, clean stop
    case requestKeyframe = 10 // TV → Mac
    case ack = 13           // TV → Mac, one per received video frame (flow control)
}

enum PacketFlags {
    static let keyframe: UInt8 = 1
}

let headerSize = 14
let tvServiceType = "_tvmirror._tcp"
let tvDefaultPort: UInt16 = 47800

func makePacket(_ type: PacketType, flags: UInt8 = 0, pts: UInt64 = 0, payload: Data = Data()) -> Data {
    var d = Data(capacity: headerSize + payload.count)
    d.append(type.rawValue)
    d.append(flags)
    withUnsafeBytes(of: pts.bigEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { d.append(contentsOf: $0) }
    d.append(payload)
    return d
}
