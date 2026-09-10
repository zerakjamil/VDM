import SwiftUI
import UniformTypeIdentifiers

public struct FloatingDropZoneView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    @State private var showSuccessAnimation = false

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isTargeted ? Color.cyan : Color.white.opacity(0.15),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [6] : [])
                        )
                )
                .shadow(color: isTargeted ? Color.cyan.opacity(0.4) : Color.black.opacity(0.2), radius: isTargeted ? 12 : 6)

            VStack(spacing: 8) {
                Image(systemName: showSuccessAnimation ? "checkmark.circle.fill" : (isTargeted ? "arrow.down.circle.fill" : "plus.circle.dashed"))
                    .font(.system(size: 28))
                    .foregroundColor(showSuccessAnimation ? .green : (isTargeted ? .cyan : .secondary))
                    .scaleEffect(isTargeted ? 1.15 : 1.0)
                    .animation(.spring(), value: isTargeted)

                Text(showSuccessAnimation ? "Download Added!" : (isTargeted ? "Drop to Download" : "Drop Link Here"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isTargeted ? .cyan : .secondary)
            }
            .padding(14)
        }
        .frame(width: 140, height: 90)
        .onDrop(of: [.url, .plainText], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }

            // Check URL
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let validUrl = url {
                    DispatchQueue.main.async {
                        self.handleDroppedUrl(validUrl)
                    }
                }
            }

            // Check String
            _ = provider.loadObject(ofClass: String.self) { str, _ in
                if let validStr = str, let url = URL(string: validStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    DispatchQueue.main.async {
                        self.handleDroppedUrl(url)
                    }
                }
            }

            return true
        }
    }

    private func handleDroppedUrl(_ url: URL) {
        showSuccessAnimation = true
        appState.addDownload(
            url: url,
            destinationDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!,
            segments: 16,
            startImmediately: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.showSuccessAnimation = false
        }
    }
}
