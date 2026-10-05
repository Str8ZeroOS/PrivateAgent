import SwiftUI
import AgentCore

public struct WorkspaceSnapshotPublisher: ViewModifier {
    let screen: InAppScreen
    var extraVisibleText: [String]
    var extraControls: [AgentControl]
    var traits: [String: String]

    public init(
        screen: InAppScreen,
        extraVisibleText: [String] = [],
        extraControls: [AgentControl] = [],
        traits: [String: String] = [:]
    ) {
        self.screen = screen
        self.extraVisibleText = extraVisibleText
        self.extraControls = extraControls
        self.traits = traits
    }

    public func body(content: Content) -> some View {
        content
            .onAppear { publish() }
            .onChange(of: extraVisibleText) { _, _ in publish() }
            .onChange(of: extraControls.map(\.id)) { _, _ in publish() }
            .onChange(of: traitsDescription) { _, _ in publish() }
    }

    private var traitsDescription: String {
        traits.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "|")
    }

    private func publish() {
        let snapshot = AccessibilitySnapshot(
            screen: screen,
            visibleText: InAppWorkspace.visibleText(on: screen) + extraVisibleText,
            controls: AccessibilitySnapshotMerge.controls(
                catalog: InAppWorkspace.controls(on: screen),
                live: extraControls
            ),
            traits: traits
        )
        Task {
            await InAppWorkspaceStore.shared.publish(snapshot)
        }
    }
}

extension View {
    public func workspaceSnapshot(
        _ screen: InAppScreen,
        extraVisibleText: [String] = [],
        extraControls: [AgentControl] = [],
        traits: [String: String] = [:]
    ) -> some View {
        modifier(
            WorkspaceSnapshotPublisher(
                screen: screen,
                extraVisibleText: extraVisibleText,
                extraControls: extraControls,
                traits: traits
            )
        )
    }
}
