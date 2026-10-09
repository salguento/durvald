import SwiftUI

enum RatingPreferences {
    static let enabledKey = "ratings.enabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            || UserDefaults.standard.bool(forKey: enabledKey)
    }
}

struct RatingControl: View {
    let rating: UInt8?
    var identity: PersonalEditIdentity? = nil
    var isEditable = false
    var accentForeground: Color = .accentColor
    var onChange: (UInt8?) -> Void = { _ in }
    var onCommit: ((UInt8?) async -> Bool)? = nil
    @State private var edit: PersonalValueEdit<UInt8?>

    init(
        rating: UInt8?,
        isEditable: Bool = false,
        accentForeground: Color = .accentColor,
        identity: PersonalEditIdentity? = nil,
        onChange: @escaping (UInt8?) -> Void = { _ in },
        onCommit: ((UInt8?) async -> Bool)? = nil
    ) {
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
            ForEach(1...5, id: \.self) { value in
                Button {
                    guard isEditable else { return }
                    let value = PersonalValueLabels.ratingAfterClick(UInt8(value), current: edit.value)
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
                } label: {
                    Image(systemName: value <= Int(edit.value ?? 0) ? "star.fill" : "star")
                        .foregroundStyle(value <= Int(edit.value ?? 0) ? accentForeground : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel(PersonalValueLabels.star(value))
            }
        }
        .onChange(of: identity, initial: true) { _, _ in edit.reset(rating) }
        .onChange(of: rating) { _, updatedRating in
            edit.receive(updatedRating)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Avaliação")
        .accessibilityValue(PersonalValueLabels.rating(edit.value))
    }
}
