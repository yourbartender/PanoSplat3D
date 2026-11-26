import SwiftUI

public struct ContentView: View {
    @Bindable var coordinator: PipelineCoordinator

    public init(coordinator: PipelineCoordinator = PipelineCoordinator()) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                BrushStatusBarView(coordinator: coordinator)
                PanoramaDropZoneView(coordinator: coordinator)
                OutputDestinationView(coordinator: coordinator)
                ParametersPanelView(coordinator: coordinator)
                HelpTipsView(coordinator: coordinator)
                ProgressFooterView(coordinator: coordinator)
            }
            .padding(14)
        }
        .frame(minWidth: 740, idealWidth: 840, minHeight: 620, idealHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
