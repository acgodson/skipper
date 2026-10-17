import SwiftUI

// Controller UI floats over the remote picture, which is an AppKit view and cannot see its
// SwiftUI siblings. Anything marked as a local control reports its frame upwards, so the
// picture knows which parts of itself belong to this Mac: the pointer stays visible there and
// nothing that happens there is forwarded.

public enum SessionStage {
    public static let coordinateSpaceName = "skipper.session.stage"
    public static var coordinateSpace: CoordinateSpace { .named(coordinateSpaceName) }
}

public struct LocalControlRegionsKey: PreferenceKey {
    public static var defaultValue: [CGRect] { [] }
    public static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

public extension View {

    func localControlRegion(_ active: Bool = true) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LocalControlRegionsKey.self,
                    value: active ? [proxy.frame(in: SessionStage.coordinateSpace)] : [])
            }
        )
    }

    func sessionStage(onLocalControlRegionsChange action: @escaping ([CGRect]) -> Void) -> some View {
        coordinateSpace(name: SessionStage.coordinateSpaceName)
            .onPreferenceChange(LocalControlRegionsKey.self, perform: action)
    }
}
