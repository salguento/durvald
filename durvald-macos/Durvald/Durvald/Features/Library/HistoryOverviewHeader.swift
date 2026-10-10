import Charts
import SwiftUI

struct HistoryOverviewHeader: View {
    let snapshot: HistoryWeekSnapshot
    private let barScale: CGFloat = 0.75
    private var barGroupSpan: CGFloat { 0.8 * barScale }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 32) {
                statistics.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
                weeklyChart.frame(minWidth: 320, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 24) {
                statistics
                weeklyChart
            }
        }
        .padding(24)
        .accessibilityIdentifier("history.overview.header")
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: snapshot.trendIcon)
                    .accessibilityHidden(true)
                if let change = snapshot.percentageChange {
                    Text("\(abs(change).formatted(.number.precision(.fractionLength(0...1))))% vs semana passada")
                } else {
                    Text("Sem reproduções na semana passada")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.currentTotal.formatted())
                    .font(.system(size: 48, weight: .bold))
                    .monospacedDigit()
                Text(snapshot.currentTotal == 1 ? "música" : "músicas")
                    .font(.title.weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Músicas ouvidas nesta semana")
        .accessibilityValue(accessibleSummary)
    }

    private var accessibleSummary: String {
        let total = snapshot.currentTotal.formatted()
        guard let change = snapshot.percentageChange else {
            return "\(total) músicas. Sem reproduções na semana passada para calcular a variação."
        }
        let trend = change == 0 ? "Sem alteração" : change > 0 ? "Aumento" : "Diminuição"
        return "\(total) músicas. \(trend) de \(abs(change).formatted(.number.precision(.fractionLength(0...1))))% em relação à semana passada."
    }

    private enum Week: String, CaseIterable, Identifiable {
        case current, previous
        var id: Self { self }
        var title: String { self == .current ? "Esta semana" : "Semana passada" }
        func count(for day: HistoryWeekSnapshot.Day) -> Int {
            self == .current ? day.current : day.previous
        }
    }

    private func dayKey(_ day: HistoryWeekSnapshot.Day) -> String {
        day.date.timeIntervalSinceReferenceDate.description
    }

    private var weeklyChart: some View {
        Chart(snapshot.days) { day in
            ForEach(Week.allCases) { week in
                bar(day: day, week: week)
            }
        }
        // Categorical days put ticks at each pair's center instead of at the
        // midnight boundary of a continuous date interval.
        .chartXScale(domain: snapshot.days.map(dayKey))
        .chartForegroundStyleScale(domain: Week.allCases.map(\.title),
                                   range: [Color.primary, Color.secondary.opacity(0.55)])
        .chartLegend(position: .top, alignment: .trailing, spacing: 12)
        .chartYScale(domain: 0...(Double(max(1, snapshot.days.map { max($0.current, $0.previous) }.max() ?? 0)) / Double(barScale)))
        .chartXAxis {
            AxisMarks(values: snapshot.days.map(dayKey)) { value in
                AxisValueLabel {
                    if let key = value.as(String.self),
                       let day = snapshot.days.first(where: { dayKey($0) == key }) {
                        Text(weekdayLabel(day.date, abbreviated: true))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    HistoryChartTooltips(regions: tooltipRegions(proxy: proxy, plot: plot))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 210)
        .accessibilityLabel("Reproduções por dia, comparadas à semana passada")
        .accessibilityIdentifier("history.overview.weeklyChart")
    }

    private func bar(day: HistoryWeekSnapshot.Day, week: Week) -> some ChartContent {
        BarMark(x: .value("Dia", dayKey(day)), y: .value("Músicas", Double(week.count(for: day))), width: .ratio(1))
            .foregroundStyle(by: .value("Semana", week.title))
            .position(by: .value("Semana", week.title), axis: .horizontal, span: .ratio(barGroupSpan))
            .accessibilityLabel(Text(weekdayLabel(day.date)))
            .accessibilityValue("\(week.title): \(week.count(for: day)) músicas")
    }

    private func weekdayLabel(_ date: Date, abbreviated: Bool = false) -> String {
        let label = date.formatted(.dateTime.weekday(abbreviated ? .abbreviated : .wide)
            .locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: "")
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private func barTooltip(day: HistoryWeekSnapshot.Day, week: Week) -> String {
        let count = week.count(for: day)
        let weekday = weekdayLabel(day.date)
        return "\(weekday) · \(week.title)\n\(count.formatted()) \(count == 1 ? "música" : "músicas")"
    }

    private func tooltipRegions(proxy: ChartProxy, plot: CGRect) -> [HistoryChartTooltipRegion] {
        snapshot.days.flatMap { day in
            Week.allCases.compactMap { week in
                guard let frame = barFrame(day: day, week: week, proxy: proxy, plot: plot) else { return nil }
                return HistoryChartTooltipRegion(frame: frame, text: barTooltip(day: day, week: week))
            }
        }
    }

    private func barFrame(day: HistoryWeekSnapshot.Day, week: Week, proxy: ChartProxy, plot: CGRect) -> CGRect? {
        guard let band = proxy.positionRange(forX: dayKey(day)),
              let baseline = proxy.position(forY: 0.0),
              let top = proxy.position(forY: Double(week.count(for: day))) else { return nil }
        // Keep each native tooltip's bounds aligned with the reduced bars.
        let groupWidth = (band.upperBound - band.lowerBound) * barGroupSpan
        let width = groupWidth / 2
        let center = (band.lowerBound + band.upperBound) / 2
        let x = center - groupWidth / 2 + (week == .previous ? width : 0)
        let height = max(2, baseline - top)
        return CGRect(x: plot.minX + x, y: plot.minY + baseline - height, width: width, height: height)
    }
}
