import Foundation
import RCTestKit
import RemoteControlCore

private func pair(_ id: String, local: String, remote: String,
                  state: String = "succeeded", sent: Int = 0, received: Int = 0,
                  extra: [String: Any] = [:]) -> (type: String, values: [String: Any]) {
    var values: [String: Any] = [
        "id": id,
        "localCandidateId": local,
        "remoteCandidateId": remote,
        "state": state,
        "bytesSent": NSNumber(value: sent),
        "bytesReceived": NSNumber(value: received),
    ]
    for (key, value) in extra { values[key] = value }
    return (type: "candidate-pair", values: values)
}

private func candidate(_ id: String, _ type: String, local: Bool,
                       relayProtocol: String = "") -> (type: String, values: [String: Any]) {
    var values: [String: Any] = ["id": id, "candidateType": type]
    if !relayProtocol.isEmpty { values["relayProtocol"] = relayProtocol }
    return (type: local ? "local-candidate" : "remote-candidate", values: values)
}

public let icePathSuite = TestSuite("ICEPathStatistics", [

    TestCase("the transport's selectedCandidatePairId wins over every other pair") {
        let stats = ICEPathStatistics.parse([
            (type: "transport", values: ["id": "T1", "selectedCandidatePairId": "P2"]),
            pair("P1", local: "L1", remote: "R1", sent: 9_000_000, received: 9_000_000),
            pair("P2", local: "L2", remote: "R2", sent: 4096, received: 8192),
            candidate("L1", "host", local: true),
            candidate("R1", "host", local: false),
            candidate("L2", "relay", local: true, relayProtocol: "udp"),
            candidate("R2", "relay", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.selected, true)
        try expectEqual(path.localCandidateType, "relay")
        try expectEqual(path.remoteCandidateType, "relay")
        try expectEqual(path.localRelayProtocol, "udp")
        try expectEqual(path.bytesSent, 4096)
        try expectEqual(path.bytesReceived, 8192)
        try expectEqual(path.sendsThroughRelay, true)
        try expectEqual(path.usesRelay, true)
        try expectEqual(path.movedBytes, true)
    },

    TestCase("a relay-only session reports relay on both ends") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", sent: 120_000, received: 3_400_000,
                 extra: ["selected": NSNumber(value: true),
                         "currentRoundTripTime": NSNumber(value: 0.048)]),
            candidate("L1", "relay", local: true, relayProtocol: "udp"),
            candidate("R1", "relay", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.sendsThroughRelay, true)
        try expectClose(path.roundTripMs, 48.0, tolerance: 1e-6)
    },

    TestCase("a peer-to-peer session is not reported as relayed") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", sent: 500, received: 700,
                 extra: ["selected": NSNumber(value: true)]),
            candidate("L1", "host", local: true),
            candidate("R1", "host", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.sendsThroughRelay, false)
        try expectEqual(path.usesRelay, false)
    },

    TestCase("a server-reflexive local candidate against a relayed peer still counts as relayed") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", extra: ["selected": NSNumber(value: true)]),
            candidate("L1", "srflx", local: true),
            candidate("R1", "relay", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.sendsThroughRelay, false,
                        "our own media did not leave through a TURN server")
        try expectEqual(path.usesRelay, true, "a TURN server still carried the traffic")
    },

    TestCase("with no selected or nominated pair the busiest succeeded pair is reported") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", received: 10),
            pair("P2", local: "L2", remote: "R2", received: 2_000_000),
            candidate("L1", "host", local: true),
            candidate("R1", "host", local: false),
            candidate("L2", "relay", local: true),
            candidate("R2", "relay", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.localCandidateType, "relay")
        try expectEqual(path.selected, false, "nothing claimed this pair was selected")
    },

    TestCase("a nominated succeeded pair beats a succeeded one that was not nominated") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", received: 9_000_000),
            pair("P2", local: "L2", remote: "R2", received: 1,
                 extra: ["nominated": NSNumber(value: true)]),
            candidate("L1", "host", local: true),
            candidate("R1", "host", local: false),
            candidate("L2", "relay", local: true),
            candidate("R2", "relay", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.localCandidateType, "relay")
    },

    TestCase("a pair that never succeeded is not reported") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", state: "in-progress", received: 1_000),
            candidate("L1", "relay", local: true),
            candidate("R1", "relay", local: false),
        ])
        try expectNil(stats, "an unsucceeded pair must not be read as the path media took")
    },

    TestCase("a report with no candidate pairs at all yields nothing") {
        let stats = ICEPathStatistics.parse([
            (type: "inbound-rtp", values: ["id": "I1", "kind": "video",
                                           "framesDecoded": NSNumber(value: 10)]),
            (type: "transport", values: ["id": "T1", "selectedCandidatePairId": ""]),
        ])
        try expectNil(stats)
    },

    TestCase("bytes in one direction only is not media moving both ways") {
        let stats = ICEPathStatistics.parse([
            pair("P1", local: "L1", remote: "R1", sent: 4_000, received: 0,
                 extra: ["selected": NSNumber(value: true)]),
            candidate("L1", "relay", local: true),
            candidate("R1", "relay", local: false),
        ])
        let path = try expectNotNil(stats)
        try expectEqual(path.movedBytes, false)
    },
])
