import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif

// MARK: - Video Call View

/// Full-screen video call UI with encrypted video feed placeholders.
/// Provides camera, mic, speaker, and flip controls over a dark canvas.
/// Designed as a UI-ready scaffold; video capture is integrated at runtime.
struct VideoCallView: View {
    @EnvironmentObject var appState: AppState

    @State private var isMuted = false
    @State private var isCameraOn = true
    @State private var isRearCamera = false
    @State private var isSpeaker = true
    @State private var showControls = true
    /// W391 — local pipeline reference. Held by AppState (lifecycle
    /// bound to the active call). When non-nil, the placeholders are
    /// replaced by real LocalCameraPreview / RemoteVideoDisplay views.
    @State private var pipelineRef: VideoCallPipeline?

    var body: some View {
        ZStack {
            // Full-screen dark background (remote video placeholder)
            Color.black.ignoresSafeArea()

            // Remote video placeholder
            remoteVideoPlaceholder

            VStack {
                // Top bar: contact info + security badge
                if showControls {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                // Local camera preview (picture-in-picture)
                if isCameraOn {
                    localPreview
                }

                // Waveform overlay (if enabled during video call)
                if appState.waveformEnabled {
                    WaveformPanel()
                        .padding(.bottom, 8)
                }

                // Bottom controls
                if showControls {
                    bottomControls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 40)
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .statusBarHidden(!showControls)
    }

    // MARK: - Remote Video Placeholder

    @ViewBuilder
    private var remoteVideoPlaceholder: some View {
        if let pipeline = pipelineRef ?? appState.videoPipeline {
            // W391: iOS↔iOS remote video — AVSampleBufferDisplayLayer
            // consumes decoded CVPixelBuffers from the BCrypto HEVC pipeline.
            RemoteVideoDisplay(pipeline: pipeline)
                .ignoresSafeArea()
        } else {
            #if canImport(WebRTC)
            if let track = appState.remoteWebRtcVideoTrack as? RTCVideoTrack {
                // Android↔iOS remote video — WebRTC RTP track displayed via
                // Metal-backed RTCMTLVideoView. Shown when the peer (Android)
                // sends video over WebRTC rather than the BCrypto WS pipeline.
                WebRTCRemoteVideoView(track: track)
                    .ignoresSafeArea()
            } else {
                remoteVideoFallback
            }
            #else
            remoteVideoFallback
            #endif
        }
    }

    private var remoteVideoFallback: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))

            Text("Video cifrato")
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))

            Text("\(appState.videoCodec) + AES-256-GCM")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green.opacity(0.5))
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.callContactId ?? "Videochiamata")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)

                    Text("Cifrato \u{2022} \(appState.videoCodecLabel)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            CallSecurityBadge()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Local Camera Preview (PiP)

    @ViewBuilder
    private var localPreview: some View {
        HStack {
            Spacer()
            ZStack {
                if let pipeline = pipelineRef ?? appState.videoPipeline {
                    // W391: real local camera — AVCaptureVideoPreview
                    // Layer attached to the pipeline's session.
                    LocalCameraPreview(pipeline: pipeline)
                        .frame(width: 120, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                        .frame(width: 120, height: 160)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "person.fill")
                                    .font(.title)
                                    .foregroundColor(.gray)
                                Text("Tu")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
            .padding(.trailing, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 24) {
            videoButton(
                icon: "camera.rotate.fill",
                label: "Inverti"
            ) {
                isRearCamera.toggle()
                // W393: real flip via the pipeline (front ↔ back).
                appState.videoFlipCamera()
            }

            videoButton(
                icon: isCameraOn ? "video.fill" : "video.slash.fill",
                label: isCameraOn ? "Cam ON" : "Cam OFF",
                isActive: !isCameraOn
            ) {
                isCameraOn.toggle()
                // W393: pause/resume the AVCaptureSession without
                // tearing down encoder / fragmenter / transport.
                appState.videoSetCameraEnabled(isCameraOn)
            }

            videoButton(
                icon: isMuted ? "mic.slash.fill" : "mic.fill",
                label: isMuted ? "Riattiva" : "Muto",
                isActive: isMuted
            ) {
                isMuted.toggle()
                appState.setMuted(isMuted)
            }

            videoButton(
                icon: "phone.down.fill",
                label: "Termina",
                isEndCall: true
            ) {
                appState.endCall()
            }

            videoButton(
                icon: isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Altoparlante",
                isActive: isSpeaker
            ) {
                isSpeaker.toggle()
                appState.setSpeaker(isSpeaker)
            }
        }
    }

    // MARK: - Video Control Button

    private func videoButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        isEndCall: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 50, height: 50)
                    .background(
                        isEndCall
                            ? Color.red
                            : (isActive ? Color.blue : Color.white.opacity(0.15))
                    )
                    .clipShape(Circle())
                    .foregroundColor(.white)

                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
struct VideoCallView_Previews: PreviewProvider {
    static var previews: some View {
        VideoCallView()
            .environmentObject(previewAppState())
    }

    static func previewAppState() -> AppState {
        let state = AppState()
        state.callContactId = "Alice"
        state.callState = .encrypted
        state.isVideoCall = true
        state.isInCall = true
        return state
    }
}
#endif
