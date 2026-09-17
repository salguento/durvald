import SwiftUI

enum CollectionListingMode: String, CaseIterable, Identifiable {
    case compact, standard, compactGrid, standardGrid

    var id: Self { self }
    var isGrid: Bool { self == .compactGrid || self == .standardGrid }
    var title: String {
        switch self {
        case .compact: "Compacta"
        case .standard: "Default"
        case .compactGrid: "Grid compacto"
        case .standardGrid: "Grid default"
        }
    }
    var icon: String {
        switch self {
        case .compact: "text.justify"
        case .standard: "list.bullet"
        case .compactGrid: "square.grid.3x3"
        case .standardGrid: "square.grid.2x2"
        }
    }
}

struct CollectionListingMenu: View {
    @Binding var mode: CollectionListingMode
    var controlSize: CGFloat = 32
    var controlWidth: CGFloat? = nil
    var body: some View {
        Menu {
            Picker("Visualização", selection: $mode) {
                ForEach(CollectionListingMode.allCases) { option in
                    Label(option.title, systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .frame(width: controlWidth ?? controlSize, height: controlSize)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: controlWidth ?? controlSize, height: controlSize)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Visualização da listagem")
        .accessibilityLabel("Visualização da listagem")
        .accessibilityValue(mode.title)
    }
}

struct CollectionListingLayout<Content: View>: View {
    let mode: CollectionListingMode
    var isSidebar = false
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            let padding: CGFloat = isSidebar ? 10 : 24
            let spacing: CGFloat = isSidebar ? 6 : 16
            let width = max(1, geometry.size.width - padding * 2)
            let target: CGFloat = isSidebar ? (mode == .compactGrid ? 66 : 110) : (mode == .compactGrid ? 120 : 192)
            let count = max(1, Int((width + spacing) / (target + spacing)))
            let size = isSidebar ? max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count)) : min(target, width)
            ScrollView {
                Group {
                    if mode.isGrid {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: spacing, alignment: .top), count: count), alignment: .leading, spacing: spacing) {
                            content(size)
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: isSidebar ? 2 : 4) {
                            content(isSidebar ? 32 : 42)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, padding)
                .padding(.vertical, isSidebar ? 4 : 24)
            }
            .preservesLibraryScrollPosition()
        }
    }
}

struct CollectionListingItem<Artwork: View>: View {
    let title: String
    var subtitle: String? = nil
    let mode: CollectionListingMode
    let artworkSize: CGFloat
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    @State private var isHovered = false
    @State private var showsTooltip = false

    var body: some View {
        Button(action: action) {
            Group {
                if mode.isGrid {
                    VStack(alignment: .leading, spacing: 7) {
                        artwork()
                        if mode == .standardGrid {
                            textDetails
                        }
                    }
                    .frame(width: artworkSize, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        if mode == .standard { artwork() }
                        if mode == .compact {
                            Text("\(title)\(Text(subtitle.map { " · \($0)" } ?? "").foregroundColor(.secondary))")
                                .lineLimit(1)
                        } else {
                            textDetails
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, mode == .compact ? 7 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1))
            }
        }
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .task(id: isHovered) {
            guard isHovered, mode == .compactGrid else { showsTooltip = false; return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            showsTooltip = true
        }
        .onChange(of: mode) { _, _ in showsTooltip = false }
        .popover(isPresented: $showsTooltip, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: 260, alignment: .leading)
            .preferredColorScheme(.dark)
        }
    }

    private var textDetails: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(AlbumListingTypography.title).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(AlbumListingTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
