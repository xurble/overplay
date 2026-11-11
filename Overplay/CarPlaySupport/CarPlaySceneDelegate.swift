import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let coordinator = CarPlayCoordinator()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        guard AppRuntime.shared.libraryStoreFailure == nil else {
            // Nothing else runs without the library (`STORE-001`).
            let template = CPListTemplate(title: "Overplay", sections: [])
            template.emptyViewTitleVariants = ["Can't Open Your Library"]
            template.emptyViewSubtitleVariants = ["Open Overplay on your iPhone for details."]
            interfaceController.setRootTemplate(template, animated: false, completion: nil)
            return
        }
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
