import AppKit
import SwiftUI

enum LibraryTypography {
    static let listingTitle = Font.system(size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize + 1)
    static let listingSecondary = Font.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1)
    static let summaryTitle = Font.headline
    static let summaryDetail = Font.caption
}

enum LibrarySummaryMetrics {
    static let spacing: CGFloat = 1
    static let maximumWidth: CGFloat = 480
}

struct LibrarySummaryView: View {
    let title: String
    let text: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: LibrarySummaryMetrics.spacing) {
            Text(title).font(LibraryTypography.summaryTitle)
            Text(text).font(LibraryTypography.summaryDetail)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: LibrarySummaryMetrics.maximumWidth, alignment: .leading)
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
