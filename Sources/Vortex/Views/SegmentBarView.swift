import SwiftUI

public struct SegmentBarView: View {
    public let segments: [SegmentInfo]
    public let totalBytes: Int64

    public init(segments: [SegmentInfo], totalBytes: Int64) {
        self.segments = segments
        self.totalBytes = totalBytes
    }

    private let colors: [Color] = [
        .cyan, .blue, .indigo, .mint, .teal, .purple, .green, .orange
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))

                    // Segments
                    if totalBytes > 0 && !segments.isEmpty {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            let segTotal = Double(segment.totalBytes)
                            let segDownloaded = Double(segment.bytesDownloaded)
                            let segProgress = segTotal > 0 ? (segDownloaded / segTotal) : 0.0

                            let segStartRatio = Double(segment.startOffset) / Double(totalBytes)
                            let segWidthRatio = Double(segment.endOffset - segment.startOffset + 1) / Double(totalBytes)

                            let xOffset = geo.size.width * segStartRatio
                            let maxWidth = geo.size.width * segWidthRatio
                            let filledWidth = maxWidth * segProgress

                            // Unfilled segment chunk background
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.05))
                                .frame(width: max(1, maxWidth - 1), height: geo.size.height)
                                .offset(x: xOffset)

                            // Filled downloaded portion
                            if filledWidth > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                colors[index % colors.count].opacity(0.85),
                                                colors[index % colors.count]
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(1, filledWidth), height: geo.size.height)
                                    .offset(x: xOffset)
                                    .shadow(color: colors[index % colors.count].opacity(segment.state == .active ? 0.6 : 0.0), radius: 3)
                            }
                        }
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Sub-indicator info
            if !segments.isEmpty {
                HStack {
                    Text("\(segments.count) streams")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)

                    Spacer()

                    let activeCount = segments.filter { $0.state == .active }.count
                    if activeCount > 0 {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("\(activeCount) active")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
    }
}
