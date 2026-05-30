enum StartupAuthorizationGate {
    static func shouldShowPermissionView(
        readiness: AppleMusicReadiness,
        hasCheckedReadiness: Bool,
        hasPresentedAuthorizedUI: Bool
    ) -> Bool {
        guard !readiness.isReady else { return false }

        if !hasCheckedReadiness && hasPresentedAuthorizedUI {
            return false
        }

        return true
    }
}
