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
    var onChange: (UInt8?) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    guard isEditable else { return }
                    onChange(rating == UInt8(value) ? nil : UInt8(value))
                } label: {
                    Image(systemName: value <= Int(rating ?? 0) ? "star.fill" : "star")
                        .foregroundStyle(value <= Int(rating ?? 0) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel("\(value) de 5")
            }

            if isEditable, rating != nil {
                Button("Limpar") { onChange(nil) }
                    .buttonStyle(.borderless)
                    .padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Avaliação")
        .accessibilityValue(rating.map { "\($0) de 5" } ?? "Sem avaliação")
    }
}
