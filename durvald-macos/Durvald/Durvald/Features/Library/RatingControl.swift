import SwiftUI

enum RatingPreferences {
    static let enabledKey = "ratings.enabled"
    static func migrateFilterPreferences(_ defaults: UserDefaults = .standard) {
        let key = "albums.minimumRating.halfSteps"
        if defaults.object(forKey: key) == nil, defaults.object(forKey: "albums.minimumRating") != nil {
            defaults.set(min(5, max(0, defaults.integer(forKey: "albums.minimumRating"))) * 2, forKey: key)
        }
    }
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            || UserDefaults.standard.bool(forKey: enabledKey)
    }
}

enum RatingValues {
    static func options(_ granularity: RatingGranularity, including current: Int? = nil) -> [Int] {
        var values = Array(stride(from: 0, through: 10, by: granularity == .halfStars ? 1 : 2))
        if let current, (0...10).contains(current), !values.contains(current) { values.append(current) }
        return values.sorted()
    }
    static func number(_ halfSteps: Int) -> String {
        (Double(halfSteps) / 2).formatted(.number.precision(.fractionLength(0...1)))
    }
    static func halfSteps(ruleValue: String) -> Int? {
        guard let stars = Double(ruleValue), stars.isFinite, (0...5).contains(stars),
              (stars * 2).rounded() == stars * 2 else { return nil }
        return Int(stars * 2)
    }
    static func ruleValue(_ halfSteps: Int) -> String {
        halfSteps.isMultiple(of: 2) ? String(halfSteps / 2) : "\(halfSteps / 2).5"
    }
    static func symbol(star: Int, rating: UInt8?) -> String {
        let value = Int(rating ?? 0)
        return value >= star * 2 ? "star.fill" : value == star * 2 - 1 ? "star.leadinghalf.filled" : "star"
    }
}

struct RatingControl: View {
    @Environment(DurvaldCoreStore.self) private var store
    let rating: UInt8?
    var identity: PersonalEditIdentity? = nil
    var isEditable = false
    var accentForeground: Color = .accentColor
    var onChange: (UInt8?) -> Void = { _ in }
    var onCommit: ((UInt8?) async -> Bool)? = nil
    @State private var edit: PersonalValueEdit<UInt8?>

    init(rating: UInt8?, isEditable: Bool = false, accentForeground: Color = .accentColor,
         identity: PersonalEditIdentity? = nil, onChange: @escaping (UInt8?) -> Void = { _ in },
         onCommit: ((UInt8?) async -> Bool)? = nil) {
        self.rating = rating
        self.identity = identity
        self.isEditable = isEditable
        self.accentForeground = accentForeground
        self.onChange = onChange
        self.onCommit = onCommit
        _edit = State(initialValue: PersonalValueEdit(rating))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: RatingValues.symbol(star: star, rating: edit.value))
                    .foregroundStyle(Int(edit.value ?? 0) >= star * 2 - 1 ? accentForeground : Color.secondary)
                    .frame(width: 20, height: 22)
                    .overlay {
                        HStack(spacing: 0) {
                            if store.ratingGranularity == .halfStars { target(star * 2 - 1) }
                            target(star * 2)
                        }
                    }
                    .accessibilityHidden(!isEditable)
            }
        }
        .disabled(!isEditable || store.isChangingRatingScale)
        .onChange(of: identity, initial: true) { _, _ in edit.reset(rating) }
        .onChange(of: store.ratingScaleRevision) { _, _ in edit.reset(rating) }
        .onChange(of: rating) { _, updated in edit.receive(updated) }
        .accessibilityElement(children: isEditable ? .contain : .ignore)
        .accessibilityLabel("Avaliação")
        .accessibilityValue(PersonalValueLabels.rating(edit.value))
        .contextMenu {
            if isEditable {
                Button("Sem avaliação") { commit(nil) }
                Button("0 de 5") { commit(0) }
            }
        }
        .accessibilityAdjustableAction { direction in
            guard isEditable, !store.isChangingRatingScale else { return }
            let step = store.ratingGranularity == .halfStars ? 1 : 2
            let current = Int(edit.value ?? 0)
            switch direction {
            case .increment: commit(UInt8(min(10, current + step)))
            case .decrement: commit(UInt8(max(0, current - step)))
            @unknown default: break
            }
        }
    }

    private func target(_ halfSteps: Int) -> some View {
        Button { commit(PersonalValueLabels.ratingAfterClick(UInt8(halfSteps), current: edit.value)) } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rating.halfSteps.\(halfSteps)")
        .accessibilityAddTraits(edit.value == UInt8(halfSteps) ? .isSelected : [])
        .accessibilityLabel(PersonalValueLabels.rating(UInt8(halfSteps)))
        .help(PersonalValueLabels.rating(UInt8(halfSteps)))
    }

    private func commit(_ value: UInt8?) {
        guard isEditable, !store.isChangingRatingScale else { return }
        let ticket = edit.begin(value)
        if let onCommit {
            Task { @MainActor in
                let succeeded = await onCommit(value)
                edit.finish(ticket, succeeded: succeeded)
            }
        } else {
            onChange(value)
            edit.finish(ticket, succeeded: true)
        }
    }
}
