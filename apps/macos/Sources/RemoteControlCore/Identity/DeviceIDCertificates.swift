import Foundation

/// The registry's Device ID certificates this key holds (PROTOCOL.md v4 §1).
///
/// Normally one: the current id's. When a re-registration that presented a
/// certificate is answered with a different id, the new id and its
/// certificate are adopted and the presented certificate is kept as the
/// reclaim certificate; the next re-registration presents it to win back the
/// id other Macs knew first. Getting that id back leaves only its certificate.
/// A certificate is stored only for the id it arrived with, and only when it
/// is shaped like the registry's DER ECDSA signature; a malformed one is never
/// stored and never replaces a good one.
public struct DeviceIDCertificates: Codable, Equatable, Sendable {

    public static let derSignatureBytes = 8...72
    private static let derSequenceTag: UInt8 = 0x30

    public private(set) var byDeviceID: [String: String]
    public private(set) var reclaimDeviceID: String?

    public init(byDeviceID: [String: String] = [:], reclaimDeviceID: String? = nil) {
        self.byDeviceID = byDeviceID
        self.reclaimDeviceID = reclaimDeviceID
    }

    public static func isWellFormed(_ certificate: String) -> Bool {
        guard let der = Data(base64Encoded: certificate), derSignatureBytes.contains(der.count) else {
            return false
        }
        return der[der.startIndex] == derSequenceTag
            && Int(der[der.startIndex + 1]) == der.count - 2
    }

    public static func isDeviceID(_ value: String) -> Bool {
        value.utf8.count == DeviceID.digitCount && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    public func certificate(for deviceID: String) -> String? {
        byDeviceID[deviceID]
    }

    /// What a re-registration presents: the reclaim certificate if one is
    /// held, otherwise the current id's.
    public func presentation(currentDeviceID: String) -> (deviceID: String, certificate: String)? {
        if let reclaim = reclaimDeviceID, let certificate = byDeviceID[reclaim] {
            return (reclaim, certificate)
        }
        return byDeviceID[currentDeviceID].map { (currentDeviceID, $0) }
    }

    /// `register_ok` for `deviceID`, after presenting the certificate held for
    /// `presented` (nil when none was presented).
    public mutating func registered(deviceID: String, certificate: String?, presented: String?) {
        let kept = presented.flatMap { id in id == deviceID ? nil : byDeviceID[id].map { (id, $0) } }
        var next: [String: String] = [:]
        if let kept { next[kept.0] = kept.1 }
        if let certificate, Self.isWellFormed(certificate) {
            next[deviceID] = certificate
        } else if kept == nil, let existing = byDeviceID[deviceID] {
            next[deviceID] = existing
        }
        byDeviceID = next
        reclaimDeviceID = kept?.0
    }

    /// `hello_ok` for the current id: a newer certificate for it replaces the old one.
    public mutating func confirmed(deviceID: String, certificate: String) {
        guard Self.isWellFormed(certificate) else { return }
        byDeviceID[deviceID] = certificate
    }
}
