#if canImport(SwiftUI)
import SwiftUI

public struct NfcExchangeView: View {
    @StateObject private var driver = NfcExchangeDriver()

    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()
            stateIcon
            stateLabel
            stateHelp
            Spacer()
            actionButton
            Spacer().frame(height: 32)
        }
        .padding()
        .navigationTitle("NFC Pairing")
    }

    private var stateIcon: some View {
        Group {
            switch driver.state {
            case .idle:        Image(systemName: "wave.3.right.circle")
            case .waiting:     Image(systemName: "antenna.radiowaves.left.and.right")
            case .exchanging:  Image(systemName: "arrow.triangle.2.circlepath")
            case .success:     Image(systemName: "checkmark.shield.fill")
            case .error:       Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .font(.system(size: 64))
        .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch driver.state {
        case .idle: return .secondary
        case .waiting, .exchanging: return .blue
        case .success: return .green
        case .error: return .red
        }
    }

    private var stateLabel: some View {
        Text(stateLabelText).font(.title3.weight(.semibold))
    }

    private var stateLabelText: String {
        switch driver.state {
        case .idle: return "Ready to pair"
        case .waiting: return "Hold your iPhone near the Android device"
        case .exchanging: return "Exchanging keys\u{2026}"
        case .success(let peer): return "Paired with \(peer)"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var stateHelp: some View {
        Text("iPhone acts as the NFC reader. Android device must have Q-Audion\u{2019}s HCE service enabled.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch driver.state {
        case .idle, .error:
            Button(action: driver.start) {
                Label("Start pairing", systemImage: "play.fill")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.blue).foregroundStyle(.white).clipShape(Capsule())
            }
        case .waiting, .exchanging:
            Button(action: driver.cancel) {
                Label("Cancel", systemImage: "xmark")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.gray).foregroundStyle(.white).clipShape(Capsule())
            }
        case .success:
            Button(action: driver.reset) {
                Label("Done", systemImage: "checkmark")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.green).foregroundStyle(.white).clipShape(Capsule())
            }
        }
    }
}

@MainActor
private final class NfcExchangeDriver: ObservableObject {
    private let service = NfcCollaborativeExchange()
    @Published private(set) var state: NfcExchangeViewModel.State = .idle

    func start() {
        service.start()
        sync()
    }

    func cancel() {
        service.cancel()
        sync()
    }

    func reset() {
        // Drive state machine from .success back to .idle.
        // (.success → .idle is an allowed transition in NfcExchangeViewModel.)
        service.cancel()
        sync()
    }

    private func sync() {
        state = service.viewModel.state
    }
}

#Preview {
    NavigationStack { NfcExchangeView() }
}
#endif
