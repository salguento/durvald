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
    var isEditable = false
    var accentForeground: Color = .accentColor
    var onChange: (UInt8?) -> Void = { _ in }
    @State private var selectedRating: UInt8?

    init(
        rating: UInt8?,
        isEditable: Bool = false,
        accentForeground: Color = .accentColor,
        onChange: @escaping (UInt8?) -> Void = { _ in }
    ) {
        self.rating = rating
        self.isEditable = isEditable
        self.accentForeground = accentForeground
        self.onChange = onChange
        _selectedRating = State(initialValue: rating)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    guard isEditable else { return }
                    let updatedRating = selectedRating == UInt8(value) ? nil : UInt8(value)
                    selectedRating = updatedRating
                    onChange(updatedRating)
                } label: {
                    Image(systemName: value <= Int(selectedRating ?? 0) ? "star.fill" : "star")
                        .foregroundStyle(value <= Int(selectedRating ?? 0) ? accentForeground : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel("\(value) de 5")
            }
        }
        .onChange(of: rating) { _, updatedRating in
            selectedRating = updatedRating
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Avaliação")
        .accessibilityValue(selectedRating.map { "\($0) de 5" } ?? "Sem avaliação")
    }
}
