import Foundation

/// The ICE candidate pair libwebrtc actually settled on, and what it has carried.
/// `VideoStatistics` answers "is a picture moving"; this answers "by which route".
public struct ICEPathStatistics: Equatable, Codable {
    public var localCandidateType: String = ""
    public var remoteCandidateType: String = ""
    public var localRelayProtocol: String = ""
    public var bytesSent: Int = 0
    public var bytesReceived: Int = 0
    public var roundTripMs: Double = 0
    public var selected: Bool = false

    public init() {}

    /// True when this end's own media leaves through a TURN server. This is the one that
    /// distinguishes a forced-relay session from a peer-to-peer one on the same machine.
    public var sendsThroughRelay: Bool { localCandidateType == Self.relayCandidateType }

    /// True when either end's candidate is relayed, so a TURN server carried the traffic.
    public var usesRelay: Bool {
        localCandidateType == Self.relayCandidateType || remoteCandidateType == Self.relayCandidateType
    }

    public var movedBytes: Bool { bytesSent > 0 && bytesReceived > 0 }

    public static func parse(_ entries: [(type: String, values: [String: Any])]) -> ICEPathStatistics? {
        var pairs: [String: [String: Any]] = [:]
        var candidates: [String: [String: Any]] = [:]
        var selectedPairID: String?

        for entry in entries {
            guard let id = entry.values["id"] as? String else { continue }
            switch entry.type {
            case candidatePairType:
                pairs[id] = entry.values
            case localCandidateStatType, remoteCandidateStatType:
                candidates[id] = entry.values
            case transportStatType:
                if let selected = entry.values["selectedCandidatePairId"] as? String, !selected.isEmpty {
                    selectedPairID = selected
                }
            default:
                continue
            }
        }

        guard let (pairID, pair) = choosePair(pairs: pairs, selectedPairID: selectedPairID) else { return nil }

        var stats = ICEPathStatistics()
        stats.selected = (pairID == selectedPairID) || flag(pair, "selected")
        stats.bytesSent = int(pair, "bytesSent") ?? 0
        stats.bytesReceived = int(pair, "bytesReceived") ?? 0
        if let seconds = (pair["currentRoundTripTime"] as? NSNumber)?.doubleValue {
            stats.roundTripMs = seconds * 1000
        }
        if let local = pair["localCandidateId"] as? String, let values = candidates[local] {
            stats.localCandidateType = values["candidateType"] as? String ?? ""
            stats.localRelayProtocol = values["relayProtocol"] as? String ?? ""
        }
        if let remote = pair["remoteCandidateId"] as? String, let values = candidates[remote] {
            stats.remoteCandidateType = values["candidateType"] as? String ?? ""
        }
        return stats
    }

    private static func choosePair(pairs: [String: [String: Any]],
                                   selectedPairID: String?) -> (String, [String: Any])? {
        if let selectedPairID, let pair = pairs[selectedPairID] { return (selectedPairID, pair) }
        if let hit = pairs.first(where: { flag($0.value, "selected") }) { return (hit.key, hit.value) }
        let succeeded = pairs.filter { ($0.value["state"] as? String) == "succeeded" }
        if let hit = succeeded.first(where: { flag($0.value, "nominated") }) { return (hit.key, hit.value) }
        if let hit = succeeded.max(by: { (int($0.value, "bytesReceived") ?? 0) < (int($1.value, "bytesReceived") ?? 0) }) {
            return (hit.key, hit.value)
        }
        return nil
    }

    private static func int(_ values: [String: Any], _ key: String) -> Int? {
        (values[key] as? NSNumber)?.intValue
    }

    private static func flag(_ values: [String: Any], _ key: String) -> Bool {
        (values[key] as? NSNumber)?.boolValue ?? false
    }

    static let relayCandidateType = "relay"
    private static let candidatePairType = "candidate-pair"
    private static let localCandidateStatType = "local-candidate"
    private static let remoteCandidateStatType = "remote-candidate"
    private static let transportStatType = "transport"
}
