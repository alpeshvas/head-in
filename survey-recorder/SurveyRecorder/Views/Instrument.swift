import SwiftUI

/// "Precision navigation instrument" theme: phosphor signal on dark ink, blueprint
/// grid, monospaced technical type. Cohesive look for a magnetic-positioning tool.
enum Instrument {
    static let ink        = Color(red: 0.035, green: 0.047, blue: 0.067) // base #090C11
    static let panel      = Color(red: 0.066, green: 0.086, blue: 0.118) // raised #111620
    static let panelTop   = Color(red: 0.10,  green: 0.13,  blue: 0.17)  // sheen
    static let hairline   = Color(red: 0.16,  green: 0.20,  blue: 0.255) // borders
    static let grid       = Color(red: 0.105, green: 0.135, blue: 0.175) // blueprint lines

    // Tuned for WCAG AA on the dark panels: secondary ~6:1, tertiary ~4:1.
    static let textPrimary   = Color(red: 0.91, green: 0.94, blue: 0.97)
    static let textSecondary = Color(red: 0.64, green: 0.71, blue: 0.79) // essential labels
    static let textTertiary  = Color(red: 0.50, green: 0.57, blue: 0.65) // non-essential only

    static let phosphor = Color(red: 0.36, green: 0.94, blue: 0.74) // signal / on-route
    static let amber    = Color(red: 0.99, green: 0.78, blue: 0.40) // holding / pacing
    static let coral    = Color(red: 1.00, green: 0.50, blue: 0.50) // off-route / alert
    static let steel    = Color(red: 0.38, green: 0.45, blue: 0.55) // dim / untravelled (≥3:1 graphic)
}

/// Dark instrument backdrop: ink base + a phosphor aurora glow up top + a faint
/// blueprint grid that gives depth without competing with content.
struct InstrumentBackground: View {
    var body: some View {
        ZStack {
            Instrument.ink
            RadialGradient(
                colors: [Instrument.phosphor.opacity(0.10), .clear],
                center: .init(x: 0.5, y: -0.05), startRadius: 4, endRadius: 460
            )
            GridPattern(spacing: 30).stroke(Instrument.grid, lineWidth: 0.5).opacity(0.6)
        }
        .ignoresSafeArea()
    }
}

struct GridPattern: Shape {
    var spacing: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { p in
            var x: CGFloat = rect.minX
            while x <= rect.maxX { p.move(to: .init(x: x, y: rect.minY)); p.addLine(to: .init(x: x, y: rect.maxY)); x += spacing }
            var y: CGFloat = rect.minY
            while y <= rect.maxY { p.move(to: .init(x: rect.minX, y: y)); p.addLine(to: .init(x: rect.maxX, y: y)); y += spacing }
        }
    }
}

/// Raised panel: subtle top-to-bottom sheen, hairline border, soft drop shadow.
struct InstrumentPanel: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Instrument.panelTop, Instrument.panel],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Instrument.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func instrumentPanel(padding: CGFloat = 16) -> some View { modifier(InstrumentPanel(padding: padding)) }

    /// Tracked, uppercase, monospaced micro-label — the instrument annotation voice.
    /// Defaults to the AA-readable secondary tone (these labels are essential).
    func monoTag(_ color: Color = Instrument.textSecondary) -> some View {
        font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6).textCase(.uppercase).foregroundStyle(color)
    }
}

/// A small status chip: glowing dot + tracked mono label inside a hairline capsule.
struct InstrumentChip: View {
    let text: String
    let color: Color
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            else { Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 3) }
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0).textCase(.uppercase)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
    }
}

/// Primary action: phosphor-edged instrument button that fills on press.
/// Min 48pt tall (touch target) and visibly dims when disabled.
struct InstrumentButtonStyle: ButtonStyle {
    var tint: Color = Instrument.phosphor
    var prominent: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        InstrumentButtonLabel(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct InstrumentButtonLabel: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .tracking(1.2).textCase(.uppercase)
                .foregroundStyle(prominent ? Instrument.ink : tint)
                .frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(prominent ? tint : tint.opacity(configuration.isPressed ? 0.22 : 0.10))
                )
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(tint, lineWidth: prominent ? 0 : 1.2))
                .shadow(color: prominent && isEnabled ? tint.opacity(0.5) : .clear, radius: configuration.isPressed ? 4 : 12)
                .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
