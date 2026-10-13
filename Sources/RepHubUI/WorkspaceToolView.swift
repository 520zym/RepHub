import SwiftUI
import DesignSystem
import RepositoryApplication
import VersionControlCore

struct WorkspaceToolView: View {
    @Bindable var model: WorkspaceModel
    let request: WorkspaceToolRequest
    let palette: AppPalette
    let appearance: AppearanceStore
    @State private var shelf: RepositoryShelfModel
    @State private var partial: PartialCommitModel
    @State private var ignore: IgnoreRuleModel

    init(model: WorkspaceModel, request: WorkspaceToolRequest, palette: AppPalette, appearance: AppearanceStore) {
        self.model = model; self.request = request; self.palette = palette; self.appearance = appearance
        _shelf = State(initialValue: RepositoryShelfModel(service: model.service, binding: request.binding))
        _partial = State(initialValue: PartialCommitModel(service: model.service, binding: request.binding, path: request.path))
        _ignore = State(initialValue: IgnoreRuleModel(service: model.service, binding: request.binding, path: request.path))
    }

    var body: some View {
        Group {
            switch request.kind {
            case .inspection:
                RepositoryInspectionView(service: model.service, binding: request.binding, path: request.path,
                    palette: palette, appearance: appearance, dismiss: model.dismissTool,
                    onSelectRevision: { model.showInspectionRevision($0, binding: request.binding) })
            case .shelves:
                RepositoryShelfView(model: shelf, palette: palette, appearance: appearance, dismiss: model.dismissTool,
                    completed: {}, onBusyChange: { model.toolIsBusy = $0 })
            case .conflict:
                if let path = request.path {
                    ConflictEditorView(service: model.service, binding: request.binding, path: path, workspace: model.workspace,
                        palette: palette, appearance: appearance, dismiss: model.dismissTool, completed: { result in
                            model.applyCommitResponse(WorkspaceCommitResult(results: [], workspace: result.workspace, snapshots: result.snapshots))
                        }, onBusyChange: { model.toolIsBusy = $0 })
                }
            case .partialCommit:
                PartialCommitView(model: partial, palette: palette, appearance: appearance, dismiss: model.dismissTool,
                    completed: { _ in }, onBusyChange: { model.toolIsBusy = $0 })
            case .ignore:
                IgnoreRuleView(model: ignore, palette: palette, dismiss: model.dismissTool,
                    completed: { _ in }, onBusyChange: { model.toolIsBusy = $0 })
            }
        }
        .interactiveDismissDisabled(model.toolIsBusy)
    }
}
