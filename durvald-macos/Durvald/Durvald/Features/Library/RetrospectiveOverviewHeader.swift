import SwiftUI

struct RetrospectiveOverviewHeader: View {
    let snapshot: RetrospectiveWeekSnapshot

    private var headline: Text {
        Text("Você ouviu por \(Text(snapshot.listeningAmount).foregroundColor(.primary)) \(snapshot.listeningPeriod).")
            .foregroundColor(.secondary)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headline
                .font(.system(size: 48, weight: .bold))
                .fixedSize(horizontal: true, vertical: false)
            headline
                .font(.system(size: 36, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.listeningSentence)
        .accessibilityValue(snapshot.period.title)
        .accessibilityIdentifier("retrospective.overview.header")
    }
}
