import SwiftUI
import UIKit

/// Accent colour chosen in Settings, stored as "#RRGGBB" and applied with `.tint(_:)` at the root.
/// Views use the `.tint` shape style (not Color.accentColor, which ignores `.tint`).
enum AccentPalette {
    static let storageKey = "accentHex"
    static let defaultHex = "#FF2D55"

    struct Preset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let presets: [Preset] = [
        Preset(name: "Pink", hex: "#FF2D55"), Preset(name: "Red", hex: "#FF3B30"),
        Preset(name: "Orange", hex: "#FF9500"), Preset(name: "Yellow", hex: "#FFCC00"),
        Preset(name: "Green", hex: "#34C759"), Preset(name: "Mint", hex: "#00C7BE"),
        Preset(name: "Teal", hex: "#30B0C7"), Preset(name: "Cyan", hex: "#32ADE6"),
        Preset(name: "Blue", hex: "#007AFF"), Preset(name: "Indigo", hex: "#5856D6"),
        Preset(name: "Purple", hex: "#AF52DE"), Preset(name: "Brown", hex: "#A2845E"),
        Preset(name: "Graphite", hex: "#8E8E93"),
    ]
}

extension Color {
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            self = Color(red: 1, green: 0.176, blue: 0.333)
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        _ = UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

struct AccentPicker: View {
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultHex

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(AccentPalette.presets) { preset in
                Button {
                    accentHex = preset.hex
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if preset.hex.caseInsensitiveCompare(accentHex) == .orderedSame {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
            }
        }
        .padding(.vertical, 6)

        ColorPicker("Custom Colour", selection: Binding(
            get: { Color(hex: accentHex) },
            set: { accentHex = $0.hexString }
        ), supportsOpacity: false)
    }
}
