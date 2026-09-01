import SwiftUI
import AppKit

// MARK: - Command helper for opening About via SwiftUI Window

struct AboutCommandButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Strata") {
            openWindow(id: "about-strata")
        }
    }
}

// MARK: - Bundled metadata (generated at build time from InferenceWorker sources)

private struct AboutMetadata: Codable {
    let pythonVersion: String
    let pythonRequires: String
    let bsRoformerInferVersion: String
    let bsRoformerInferRev: String
    let bsRoformerInferShortRev: String
    let bsRoformerInferNoteRev: String
    let mlx: String
    let mlxSpectro: String
    let torch: String
    let numpy: String
    let soundfile: String
    let pyyaml: String
    let requests: String
    let tqdm: String
    let packaging: String
    let mlCollections: String
}

private enum AboutMetadataLoader {
    // Load once from app bundle; fallback to nil if missing (previews without build phase)
    static let cached: AboutMetadata? = load()

    private static func load() -> AboutMetadata? {
        // Primary: main bundle resource (normal app run)
        if let url = Bundle.main.url(forResource: "AboutMetadata", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AboutMetadata.self, from: data) {
            return decoded
        }
        // Fallback: bundle containing this type (XCTest host / SwiftUI preview)
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: "AboutMetadata", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AboutMetadata.self, from: data) {
            return decoded
        }
        return nil
    }

    private class BundleToken {}
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                inferenceSection
                Divider()
                thirdPartySection
                Divider()
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, minHeight: 520, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            appIcon
            VStack(spacing: 4) {
                Text("Strata")
                    .font(.title2.weight(.semibold))
                Text(versionString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Local-first source separation for Apple Silicon. Runs entirely on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var appIcon: some View {
        Group {
            if let nsImage = NSApp.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private var versionString: String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = dict?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    // MARK: Inference Model

    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Inference Model")
                    .font(.headline)
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
            }

            Text("Separation runs locally — no cloud. Model identity is anchored in the native app, not the worker.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                AboutDetailRow(
                    label: "Model",
                    value: "BS-RoFormer-SW",
                    link: URL(string: "https://github.com/openmirlab/bs-roformer-infer")
                )
                AboutDetailRow(
                    label: "Author",
                    value: "Jarredou",
                    link: URL(string: "https://github.com/Jarredou/BS-RoFormer")
                )
                AboutDetailRow(
                    label: "Identifier",
                    value: TrustedInferenceIdentity.model,
                    isMonospaced: true
                )
                AboutDetailRow(
                    label: "Stems",
                    value: "6 — bass, drums, other, vocals, guitar, piano"
                )
                stemPills
                AboutDetailRow(
                    label: "Checkpoint",
                    value: TrustedInferenceIdentity.checkpointSHA256,
                    isMonospaced: true,
                    isSelectable: true
                )
                Text("SHA-256 of the pinned checkpoint file. Verified before first launch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                AboutDetailRow(
                    label: "Backend",
                    value: "MLX on MPS — Apple Silicon",
                    link: URL(string: "https://github.com/ml-explore/mlx")
                )
                HStack(spacing: 4) {
                    Text("Backend id:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(TrustedInferenceIdentity.backend) / \(TrustedInferenceIdentity.device)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    private var stemPills: some View {
        // Wrap-friendly flow using flexibleHStack
        let stems = ["bass", "drums", "other", "vocals", "guitar", "piano"]
        return WrappingHStack(spacing: 6) {
            ForEach(stems, id: \.self) { stem in
                Text(stem)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlColor).opacity(0.9))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
    }

    // MARK: Third-Party

    private var thirdPartySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Third-Party Components")
                    .font(.headline)
            } icon: {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
            }
            Text("Pinned versions from InferenceWorker/pyproject.toml and uv.lock. System tools are provided externally; no version is pinned by Strata.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(ThirdPartyCatalog.entries) { entry in
                    ThirdPartyRow(entry: entry)
                    if entry.id != ThirdPartyCatalog.entries.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("© 2026 Strata")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Built for macOS. All inference runs locally on Apple Silicon.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

// MARK: - Helpers

private struct AboutDetailRow: View {
    let label: String
    let value: String
    var link: URL? = nil
    var isMonospaced: Bool = false
    var isSelectable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if isSelectable || isMonospaced {
                        Text(value)
                            .font(isMonospaced ? .caption.monospaced() : .caption)
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(value)
                    } else {
                        Text(value)
                            .font(isMonospaced ? .caption.monospaced() : .caption)
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(value)
                    }
                }
                if let link {
                    Link(destination: link) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(link.absoluteString)
                    .accessibilityLabel("Open \(label) link")
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct ThirdPartyEntry: Identifiable {
    let name: String
    let version: String
    let note: String?
    let url: URL?
    var id: String { name }
}

enum ThirdPartyCatalog {
    static var entries: [ThirdPartyEntry] {
        let m = AboutMetadataLoader.cached
        // Fallback placeholder when bundled metadata is absent (e.g., SwiftUI preview before build)
        let placeholder = "—"
        let bsVersion: String
        let bsNote: String?
        if let m {
            bsVersion = "\(m.bsRoformerInferVersion) @ \(m.bsRoformerInferShortRev)"
            bsNote = "git+https://github.com/openmirlab/bs-roformer-infer.git@\(m.bsRoformerInferNoteRev)"
        } else {
            bsVersion = placeholder
            bsNote = nil
        }
        return [
            ThirdPartyEntry(name: "bs-roformer-infer", version: bsVersion, note: bsNote, url: URL(string: "https://github.com/openmirlab/bs-roformer-infer")),
            ThirdPartyEntry(name: "mlx", version: m?.mlx ?? placeholder, note: nil, url: URL(string: "https://github.com/ml-explore/mlx")),
            ThirdPartyEntry(name: "mlx-spectro", version: m?.mlxSpectro ?? placeholder, note: nil, url: URL(string: "https://github.com/ssmall256/mlx-spectro")),
            ThirdPartyEntry(name: "torch", version: m?.torch ?? placeholder, note: nil, url: URL(string: "https://pytorch.org")),
            ThirdPartyEntry(name: "Python", version: m?.pythonVersion ?? placeholder, note: m.map { "requires-python \($0.pythonRequires)" }, url: URL(string: "https://www.python.org")),
            ThirdPartyEntry(name: "NumPy", version: m?.numpy ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://numpy.org")),
            ThirdPartyEntry(name: "SoundFile", version: m?.soundfile ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://github.com/bastibe/python-soundfile")),
            ThirdPartyEntry(name: "PyYAML", version: m?.pyyaml ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://pyyaml.org")),
            ThirdPartyEntry(name: "Requests", version: m?.requests ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://requests.readthedocs.io")),
            ThirdPartyEntry(name: "tqdm", version: m?.tqdm ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://github.com/tqdm/tqdm")),
            ThirdPartyEntry(name: "packaging", version: m?.packaging ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://github.com/pypa/packaging")),
            ThirdPartyEntry(name: "ml-collections", version: m?.mlCollections ?? placeholder, note: "locked via uv.lock", url: URL(string: "https://github.com/google/ml-collections")),
            ThirdPartyEntry(name: "FFmpeg", version: "system", note: "/opt/homebrew/bin/ffmpeg", url: URL(string: "https://ffmpeg.org")),
            ThirdPartyEntry(name: "yt-dlp", version: "system", note: "/opt/homebrew/bin/yt-dlp", url: URL(string: "https://github.com/yt-dlp/yt-dlp")),
            ThirdPartyEntry(name: "Node.js", version: "system", note: "/opt/homebrew/bin/node", url: URL(string: "https://nodejs.org")),
        ]
    }
}

private struct ThirdPartyRow: View {
    let entry: ThirdPartyEntry
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.caption.weight(.medium))
                if let note = entry.note {
                    Text(note)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(note)
                }
            }
            Spacer()
            Text(entry.version)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(entry.version)
                .textSelection(.enabled)
            if let url = entry.url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(url.absoluteString)
                .accessibilityLabel("Open \(entry.name) link")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// Simple wrappingHStack for pills (avoids LazyVGrid complexity)
private struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? 400
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                // new row
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            frames.append(frame)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            totalHeight = y + rowHeight
        }
        return (CGSize(width: totalWidth, height: totalHeight), frames)
    }
}

#Preview {
    AboutView()
        .frame(width: 480, height: 560)
}
