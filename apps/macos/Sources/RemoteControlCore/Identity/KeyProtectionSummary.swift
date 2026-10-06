import Foundation

/// What this Mac's credential storage means for its owner. Says nothing when
/// the storage is the strongest this Mac can offer, one plain sentence when it
/// is weaker, and keeps the mechanics for the Details disclosure.
public struct KeyProtectionSummary: Equatable {

    public static let weakerSentence = "This Mac can\u{2019}t protect its credentials as strongly as usual."

    public let isStrongest: Bool
    public let sentence: String?
    public let details: [String]

    public init(isStrongest: Bool, sentence: String?, details: [String]) {
        self.isStrongest = isStrongest
        self.sentence = sentence
        self.details = details
    }

    public static func make(
        keyStorage: DeviceKeyStorage,
        secretStorageMode: SecretStorageMode?,
        keyStorageNote: String?
    ) -> KeyProtectionSummary {
        var details = ["Key storage: \(keyStorage.description)"]
        if let note = secretStorageMode?.detailNote { details.append(note) }
        if let keyStorageNote { details.append(keyStorageNote) }

        let hardwareHeld = keyStorage == .secureEnclave
        let strongestSecrets = secretStorageMode.map { $0.usesDataProtectionKeychain } ?? false
        let isStrongest = hardwareHeld && strongestSecrets && keyStorageNote == nil

        return KeyProtectionSummary(
            isStrongest: isStrongest,
            sentence: isStrongest ? nil : weakerSentence,
            details: details
        )
    }
}
