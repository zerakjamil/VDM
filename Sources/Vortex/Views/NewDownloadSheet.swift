import SwiftUI
import AppKit

public struct NewDownloadSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var urlString: String = ""
    @State private var originalPageUrlString: String = ""
    @State private var customFileName: String = ""
    @State private var saveDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @State private var segments: Int = 8
    @State private var customReferer: String = ""
    @State private var customUserAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    @State private var showAdvanced: Bool = false
    @State private var errorMessage: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add New Download")
                        .font(.system(size: 16, weight: .bold))
                    Text("Multi-part accelerated download with resume & link refresh support")
                        .font(.system(size: 11))
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

            // URL input
            VStack(alignment: .leading, spacing: 5) {
                Text("Direct Download URL:")
                    .font(.system(size: 12, weight: .semibold))

                HStack {
                    TextField("https://... or magnet:?xt=...", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: urlString) { newUrl in
                            if newUrl.lowercased().hasPrefix("magnet:"), let meta = MagnetParser.parse(uri: newUrl) {
                                if customFileName.isEmpty {
                                    customFileName = meta.displayName
                                }
                            }
                        }

                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            urlString = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            if urlString.lowercased().hasPrefix("magnet:"), let meta = MagnetParser.parse(uri: urlString) {
                                if customFileName.isEmpty {
                                    customFileName = meta.displayName
                                }
                            }
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

            // Original Webpage URL (important for romsfun renewal)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Source Webpage URL (Optional):")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("Recommended for romsfun/hosts")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                TextField("e.g. https://romsfun.com/roms/playstation-3/...", text: $originalPageUrlString)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Save Directory
            VStack(alignment: .leading, spacing: 5) {
                Text("Save To:")
                    .font(.system(size: 12, weight: .semibold))

                HStack {
                    Text(saveDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button("Browse...") {
                        selectSaveDirectory()
                    }
                    .font(.system(size: 11))
                }
            }

            // Number of segments
            HStack {
                Text("Parallel Connections:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $segments) {
                    Text("4 streams").tag(4)
                    Text("8 streams (Recommended)").tag(8)
                    Text("16 streams (Fast)").tag(16)
                    Text("32 streams (Max Speed)").tag(32)
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            // Advanced Options
            DisclosureGroup("Advanced Headers (Referer & User-Agent)", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Referer:")
                            .font(.system(size: 10, weight: .medium))
                        TextField("https://...", text: $customReferer)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("User-Agent:")
                            .font(.system(size: 10, weight: .medium))
                        TextField("User-Agent", text: $customUserAgent)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 11))

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            Spacer()

            // Footer actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Paused") {
                    createDownload(startImmediately: false)
                }
                .font(.system(size: 12))

                Button("Start Download") {
                    createDownload(startImmediately: true)
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.starts(with: "http://") || clip.starts(with: "https://") || clip.lowercased().starts(with: "magnet:") {
                urlString = clip
                if clip.lowercased().starts(with: "magnet:"), let meta = MagnetParser.parse(uri: clip) {
                    if customFileName.isEmpty {
                        customFileName = meta.displayName
                    }
                }
            }
        }
    }

    private func selectSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
        }
    }

    private func createDownload(startImmediately: Bool) {
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMagnet = cleaned.lowercased().hasPrefix("magnet:")
        guard let url = URL(string: cleaned), url.scheme != nil, (url.host != nil || isMagnet) else {
            errorMessage = "Please enter a valid URL (http://, https://, or magnet:?xt=...)"
            return
        }

        var pageUrl: URL? = nil
        let cleanedPage = originalPageUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedPage.isEmpty {
            pageUrl = URL(string: cleanedPage)
        }

        var headers: [String: String] = [:]
        if !customUserAgent.isEmpty {
            headers["User-Agent"] = customUserAgent
        }
        if !customReferer.isEmpty {
            headers["Referer"] = customReferer
        } else if let p = pageUrl {
            headers["Referer"] = p.absoluteString
        }

        appState.addDownload(
            url: url,
            originalPageUrl: pageUrl,
            destinationDirectory: saveDirectory,
            fileName: customFileName.isEmpty ? nil : customFileName,
            segments: segments,
            customHeaders: headers,
            startImmediately: startImmediately
        )

        isPresented = false
    }
}
