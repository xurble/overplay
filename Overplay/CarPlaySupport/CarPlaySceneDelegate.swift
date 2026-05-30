import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let coordinator = CarPlayCoordinator()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        coordinator.connect(interfaceController: interfaceController, runtime: .shared)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator.disconnect()
    }

    func sceneDidDisconnect() {
        Task { @MainActor in
            coordinator.disconnect()
        }
    }
}
