import Cocoa

/// Shared application state.
@MainActor
final class AppState: ObservableObject {
    let itemManager = MenuBarItemManager()
    let controlItems = ControlItems()
    private(set) lazy var panelController = PanelController(appState: self)
}
