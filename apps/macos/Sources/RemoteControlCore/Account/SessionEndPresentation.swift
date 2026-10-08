// Why a session that was running stopped running, in the words the person on each Mac
// needs. The other half of EntitlementPresentation's connect-failure sentences: those
// explain a session that never started, these explain one that was taken away.
import Foundation

public struct SessionEndNotice: Equatable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public enum SessionEndPresentation {

    public static let creditRanOutHost = SessionEndNotice(
        title: "Your credit ran out",
        detail: "The session ended. Add credit to host from this Mac again.")

    public static let creditRanOutController = SessionEndNotice(
        title: "The session ended because that Mac has no credit left.")

    /// nil for every reason that needs no notice of its own, which is most of them:
    /// both peers already show the session ending, and the only reason worth a banner
    /// is one the person could not have worked out for themselves. `no_balance` is
    /// exactly that — the server is the only party that knows it (PROTOCOL.md §2.14.2).
    ///
    /// The words say what happened and what to do and never name the reason itself
    /// (DESIGN.md §4 rules 2 and 8), and the two Macs are told different things because
    /// only one of them is the one that pays.
    public static func notice(reason: String, role: SessionRole) -> SessionEndNotice? {
        guard reason == Wire.ByeReason.noBalance else { return nil }
        return role == .host ? creditRanOutHost : creditRanOutController
    }
}
