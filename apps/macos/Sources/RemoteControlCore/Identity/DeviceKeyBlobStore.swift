import Foundation
import Security

public enum DeviceKeyAccount: String, CaseIterable {
    case secureEnclave = "device-key"
    case software = "device-key-software"
}

public protocol DeviceKeyBlobStore {
    func load(_ account: DeviceKeyAccount) throws -> Data?
    func save(_ blob: Data, for account: DeviceKeyAccount) throws
    func remove(_ account: DeviceKeyAccount) throws
}

public final class InMemoryDeviceKeyStore: DeviceKeyBlobStore {

    private var blobs: [DeviceKeyAccount: Data] = [:]
    public var isSealed = false

    public init() {}

    public func load(_ account: DeviceKeyAccount) throws -> Data? {
        if isSealed { throw KeychainError.status(errSecNotAvailable) }
        return blobs[account]
    }

    public func save(_ blob: Data, for account: DeviceKeyAccount) throws {
        if isSealed { throw KeychainError.status(errSecNotAvailable) }
        blobs[account] = blob
    }

    public func remove(_ account: DeviceKeyAccount) throws {
        if isSealed { throw KeychainError.status(errSecNotAvailable) }
        blobs[account] = nil
    }
}
