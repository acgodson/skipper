import Foundation

public struct DeviceChallenge: Decodable, Equatable {
    public let nonce: String
    public let serverTime: Int64?
    public let expiresAt: Int64?

    public var nonceBytes: Data? { Data(base64Encoded: nonce) }
}

public struct DeviceTokenGrant: Decodable, Equatable {
    public let deviceToken: String
    public let expiresAt: Int64
    public let ttlSec: Int?
    public let deviceId: String
    public let accountId: String
    public let accountEmail: String?
}

public struct DeviceRecord: Decodable, Equatable {

    private enum CodingKeys: String, CodingKey {
        case deviceId, label, platform, pubkey, createdAt, linkedAt, lastSeen, trialEndsAt
    }

    public let deviceId: String
    public let label: String
    public let platform: String
    public let pubkey: String
    public let createdAt: Int64
    public let linkedAt: Int64
    public let lastSeen: Int64
    public let trialEndsAt: Int64

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? ""
        pubkey = try container.decodeIfPresent(String.self, forKey: .pubkey) ?? ""
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        linkedAt = try container.decodeIfPresent(Int64.self, forKey: .linkedAt) ?? 0
        lastSeen = try container.decodeIfPresent(Int64.self, forKey: .lastSeen) ?? 0
        trialEndsAt = try container.decodeIfPresent(Int64.self, forKey: .trialEndsAt) ?? 0
    }
}

public enum EntitlementStatus: String, Equatable {
    case trial
    case active
    case exhausted
    case unlinked

    public init(wire: String) {
        self = EntitlementStatus(rawValue: wire) ?? .exhausted
    }
}

public struct Entitlement: Decodable, Equatable {

    public struct Concurrency: Decodable, Equatable {
        public let maxActivePairs: Int

        public init(maxActivePairs: Int) { self.maxActivePairs = maxActivePairs }
    }

    public let status: EntitlementStatus
    public let tier: String
    public let balanceCents: Int64?
    public let trialEndsAt: Int64?
    public let concurrency: Concurrency
    public let refreshAfterSec: Int

    private enum CodingKeys: String, CodingKey {
        case status, tier, balanceCents, trialEndsAt, concurrency, refreshAfterSec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = EntitlementStatus(wire: try container.decode(String.self, forKey: .status))
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "base"
        balanceCents = try container.decodeIfPresent(Int64.self, forKey: .balanceCents)
        trialEndsAt = try container.decodeIfPresent(Int64.self, forKey: .trialEndsAt)
        concurrency = try container.decodeIfPresent(Concurrency.self, forKey: .concurrency)
            ?? Concurrency(maxActivePairs: 1)
        refreshAfterSec = try container.decodeIfPresent(Int.self, forKey: .refreshAfterSec) ?? 60
    }
}

public struct CachedEntitlement: Equatable {
    public let value: Entitlement
    public let fetchedAt: Date

    public init(value: Entitlement, fetchedAt: Date) {
        self.value = value
        self.fetchedAt = fetchedAt
    }

    public var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) >= TimeInterval(value.refreshAfterSec)
    }
}
