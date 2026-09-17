import Foundation

public protocol AccessCodeSink: AnyObject {
    func accessCodeDidChange(deviceID: String) async throws
}
