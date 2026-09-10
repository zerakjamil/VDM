import SwiftUI
import AppKit

public struct RefreshUrlSheet: View {
    let task: DownloadTask
    @Binding var isPresented: Bool

    @State private var newUrlString: String = ""
    @State private var isValidating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Refresh Download Address")
                        .font(.system(size: 16, weight: .bold))
                    Text("Renew expired temporary link without losing downloaded data")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Info Card: Progress Saved
            VStack(alignment: .leading, spacing: 6) {
                Text(task.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack {
                    Text("Saved Progress:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("\(SpeedTracker.formatBytes(task.downloadedBytes)) of \(SpeedTracker.formatBytes(task.totalBytes)) (\(Int(task.progress * 100))%)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }

                if case .expired(let reason) = task.status {
                    Text("Reason: \(reason)")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Step 1: Open website to generate new link
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 1: Generate Fresh Link in Browser")
                    .font(.system(size: 12, weight: .bold))

                HStack {
                    if let original = task.originalPageUrl {
                        Button {
                            NSWorkspace.shared.open(original)
                        } label: {
                            HStack {
                                Image(systemName: "safari")
                                Text("Open Website (\(original.host ?? "Source"))")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                    } else {
                        Button {
                            if let host = task.url.host {
                                if let hostUrl = URL(string: "https://\(host)") {
                                    NSWorkspace.shared.open(hostUrl)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "safari")
                                Text("Open Host Site")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                    }

                    Text("Click download in your browser to get a new direct URL.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Step 2: Paste new link
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 2: Paste New Download URL")
                    .font(.system(size: 12, weight: .bold))

                HStack {
                    TextField("https://...", text: $newUrlString)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            newUrlString = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .font(.system(size: 11))
                    }
                }
            }

            // Status feedback
            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            if let success = successMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }

            Spacer()

            // Action Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    validateAndResume()
                } label: {
                    if isValidating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 80)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Validate & Resume")
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(newUrlString.isEmpty || isValidating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onAppear {
            // Auto paste if clipboard has a valid URL
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.starts(with: "http://") || clip.starts(with: "https://") {
                if clip != task.url.absoluteString {
                    newUrlString = clip
                }
            }
        }
    }

    private func validateAndResume() {
        guard let url = URL(string: newUrlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Invalid URL format."
            return
        }

        isValidating = true
        errorMessage = nil

        Task {
            do {
                try await task.refreshUrl(newUrl: url)
                await MainActor.run {
                    isValidating = false
                    successMessage = "Link validated! Resuming download..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        isPresented = false
                    }
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
