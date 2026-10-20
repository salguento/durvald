import AppKit
import SwiftUI

extension View {
    func artworkPreview(source: ArtworkSource?, title: String) -> some View {
        modifier(ArtworkPreviewModifier(source: source, title: title))
    }
}

private struct ArtworkPreviewModifier: ViewModifier {
    let source: ArtworkSource?
    let title: String
    @State private var isPresented = false
    @State private var windowSize = CGSize(width: 900, height: 700)

    func body(content: Content) -> some View {
        Button { isPresented = true } label: { content }
            .buttonStyle(.plain)
            .help("Ampliar capa")
            .accessibilityLabel("Ampliar capa de \(title)")
            .background { ArtworkPreviewWindowSize(size: $windowSize) }
            .sheet(isPresented: $isPresented) {
                ArtworkPreviewSheet(source: source, title: title, windowSize: windowSize)
            }
    }
}

private struct ArtworkPreviewSheet: View {
    let source: ArtworkSource?
    let title: String
    let windowSize: CGSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(DurvaldCoreStore.self) private var store: DurvaldCoreStore?
    @State private var image: NSImage?

    private var imageHeight: CGFloat { windowSize.height * 0.65 }
    private var imageWidth: CGFloat {
        guard let image, image.size.height > 0 else { return imageHeight }
        return imageHeight * image.size.width / image.size.height
    }
    private var viewportWidth: CGFloat { min(imageWidth, max(1, windowSize.width - 64)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.horizontal) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: imageWidth, height: imageHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Capa de \(title)")
                .accessibilityIdentifier("artwork.preview.image")
            }
            .scrollIndicators(.hidden)
            .frame(width: viewportWidth, height: imageHeight)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .keyboardShortcut(.cancelAction)
            .help("Fechar")
            .accessibilityLabel("Fechar")
            .accessibilityIdentifier("artwork.preview.close")
            .padding(12)
        }
        .frame(width: viewportWidth, height: imageHeight)
        .presentationBackground(.clear)
        .presentationCornerRadius(0)
        .task(id: source) {
            image = nil
            guard let source else { return }
            let loaded = try? await ArtworkRepository.shared.image(
                for: source,
                pixelSize: ArtworkRepository.pixelSize(for: max(windowSize.width, imageHeight), scale: displayScale),
                using: store?.core
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Reads the presenting window, rather than the narrower detail pane or the sheet.
private struct ArtworkPreviewWindowSize: NSViewRepresentable {
    @Binding var size: CGSize

    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {
        view.onSize = { if size != $0 { size = $0 } }
        view.publishSize()
    }

    final class WindowView: NSView {
        var onSize: ((CGSize) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publishSize() }
                }
            publishSize()
        }

        func publishSize() {
            guard let window else { return }
            let size = window.frame.size
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onSize?(size)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
