import UIKit

final class CarPlaySceneDelegate: UIResponder {
    private let coordinator = CarPlayCoordinator()

    func sceneDidDisconnect() {
        Task { @MainActor in
            coordinator.disconnect()
        }
    }
}
