import Foundation

public protocol AccessCodeSink: AnyObject {
    func accessCodeDidChange(deviceID: String) async throws
}

public final class PreviewAccessCodeSink: AccessCodeSink {

    public private(set) var refreshedDeviceIDs: [String] = []

    public init() {}

    public func accessCodeDidChange(deviceID: String) async throws {
        refreshedDeviceIDs.append(deviceID)
    }
}
