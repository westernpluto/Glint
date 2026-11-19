import AVKit
import SwiftUI

/// Hosts an AVPlayerLayer for the shared player. The `primary` surface (the
/// watch screen) also owns Picture in Picture.
struct PlayerSurface: UIViewRepresentable {
    var primary: Bool = false
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = gravity
        PlayerController.shared.attach(v.playerLayer)
        if primary, AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: v.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pip.delegate = context.coordinator
            PlayerController.shared.pip = pip
            context.coordinator.pip = pip
        }
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.videoGravity = gravity
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        PlayerController.shared.detach(uiView.playerLayer)
        if let pip = coordinator.pip, PlayerController.shared.pip === pip, !pip.isPictureInPictureActive {
            PlayerController.shared.pip = nil
        }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pip: AVPictureInPictureController?

        func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
            // Synchronous: backgrounding checks this flag right after.
            MainActor.assumeIsolated { PlayerController.shared.isPiPActive = true }
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
            MainActor.assumeIsolated { PlayerController.shared.isPiPActive = true }
        }

        func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
            MainActor.assumeIsolated { PlayerController.shared.isPiPActive = false }
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
            MainActor.assumeIsolated { PlayerController.shared.isPiPActive = false }
        }

        func pictureInPictureController(_ c: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
            Task { @MainActor in
                PlayerController.shared.presentation = .expanded
                completion(true)
            }
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
