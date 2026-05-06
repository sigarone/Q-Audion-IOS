import SwiftUI
import UIKit

/// W85 — camera capture wrapper.
///
/// `PhotosPicker` (iOS 16+) only browses the existing photo library.
/// To capture a fresh photo, iOS still requires `UIImagePickerController`
/// with `sourceType: .camera` (the modern `AVCaptureSession` is overkill
/// for a one-shot photo). `NSCameraUsageDescription` is already declared
/// in `Info.plist`.
///
/// The captured `UIImage` is converted to JPEG @ quality 1.0 and handed
/// to the caller as `Data`. `ChatContainer.sendImage` does the actual
/// normalization (EXIF strip + downscale to 2048px + re-encode at 0.85
/// + 10 MB cap), so this representable just routes the raw bytes
/// through the same pipeline as the photo-library path.
///
/// Presented from `ChatDetailScreen` via `.sheet(isPresented:)`.
struct CameraPicker: UIViewControllerRepresentable {

    /// Called once with the captured JPEG bytes (quality 1.0, full
    /// camera resolution). Caller dismisses the sheet.
    let onCapture: (Data) -> Void

    /// Called when the user taps Cancel without capturing. Caller
    /// dismisses the sheet.
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // `.camera` is only available if the device has a camera —
        // simulators don't, so we fall back to .photoLibrary there
        // (which also exercises the same callback). On real devices
        // this always succeeds.
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController,
                                context: Context) {
        // No-op — picker is presented once and dismissed via callback.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject,
                             UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Use `.originalImage` (full-resolution capture) — `.editedImage`
            // would only exist with `allowsEditing = true`. ChatContainer
            // performs all downsampling downstream.
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 1.0) {
                parent.onCapture(data)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
