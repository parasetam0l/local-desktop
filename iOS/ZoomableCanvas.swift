import SwiftUI
import UIKit
import AVKit

enum DragEvent {
    case began(CGPoint) // remote coordinates
    case changed(CGPoint)
    case ended
}

/// Shared handle so the touchpad overlay and session can map screen points into remote
/// coordinates and control Picture-in-Picture.
@MainActor
final class CanvasController: ObservableObject {
    weak var canvas: CanvasScrollView?

    @Published var isPiPActive = false
    @Published var isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var isAutoPiPEnabled = false {
        didSet {
            canvas?.pictureInPicture.setAutoPiP(isAutoPiPEnabled)
        }
    }

    func togglePiP() {
        if isPiPActive {
            canvas?.pictureInPicture.stop()
        } else {
            canvas?.pictureInPicture.start()
        }
    }
}

/// The remote screen: a zoomable scroll view around the video layer. It stays
/// alive across reconnects so the last frame (and PiP) survive a dropped link.
struct ZoomableCanvas: UIViewRepresentable {
    let session: ClientSession
    let contentSize: CGSize
    let controller: CanvasController
    var onTap: ((CGPoint) -> Void)?
    var onRightTap: ((CGPoint) -> Void)?
    var onDrag: ((DragEvent) -> Void)?

    final class Coordinator {
        weak var session: ClientSession?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> CanvasScrollView {
        let view = CanvasScrollView()
        view.controller = controller
        controller.canvas = view
        view.pictureInPicture.controller = controller
        view.pictureInPicture.setAutoPiP(controller.isAutoPiPEnabled)
        context.coordinator.session = session
        session.attachVideoLayer(view.videoView.displayLayer)
        return view
    }

    func updateUIView(_ view: CanvasScrollView, context: Context) {
        view.controller = controller
        controller.canvas = view
        view.directTap = onTap
        view.directRightTap = onRightTap
        view.dragEvent = onDrag
        view.setContentSize(contentSize)
    }

    static func dismantleUIView(_ view: CanvasScrollView, coordinator: Coordinator) {
        coordinator.session?.detachVideoLayer(view.videoView.displayLayer)
    }
}
