import SwiftUI

/// eclipsereader's look: near-black surfaces, a violet-and-amber corona accent, serif wordmark.
enum Eclipse {
    /// Deep violet accent with a warm yellow highlight, kept subtle so artwork stays the focus.
    static let accent = Color(red: 0.54, green: 0.30, blue: 0.93)
    static let highlight = Color(red: 1.0, green: 0.80, blue: 0.20)
    /// One cover-card size everywhere (Browse, search, recommendations): wider on roomy screens.
    static func cardWidth(regular: Bool) -> CGFloat { regular ? 140 : 112 }
    static func cardWidth(available: CGFloat) -> CGFloat { available > 700 ? 140 : 112 }
    static let cardRadius: CGFloat = 10
    static let surface = Color(white: 0.075)
    static let surfaceHigh = Color(white: 0.12)
    static let hairline = Color.white.opacity(0.08)
    /// UI tests wait for the app to go idle; endless decorative animations would stall them.
    static let uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    static let corona = AngularGradient(colors: [accent, highlight, accent.opacity(0.5), accent], center: .center)
}

/// Black backdrop with a faint corona glow at the top; the artwork stays the brightest thing on screen.
struct EclipseBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            RadialGradient(colors: [Eclipse.accent.opacity(0.28), Eclipse.accent.opacity(0.06), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
                .frame(height: 560)
                .offset(y: -120)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The eclipse logo: a black disc with a violet-and-amber corona.
struct EclipseMark: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            Circle().fill(Eclipse.corona).blur(radius: size * 0.18).opacity(0.9)
            Circle().strokeBorder(Eclipse.corona, lineWidth: max(1.5, size * 0.07))
            Circle().fill(Color.black).padding(size * 0.11)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EclipseWordmark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 8) {
            EclipseMark(size: size)
            HStack(spacing: 0) {
                Text("eclipse").font(.system(size: size * 0.95, weight: .black, design: .serif))
                Text("reader").font(.system(size: size * 0.95, weight: .regular, design: .serif)).foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("eclipsereader")
    }
}

extension View {
    /// Raised surface used for cards and panels.
    func eclipseCard(cornerRadius: CGFloat = 18) -> some View {
        background(Eclipse.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Eclipse.hairline))
    }
}

/// Soft moving highlight shown while artwork loads.
struct ShimmerView: View {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Color.white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.8)
                .offset(x: phase * g.size.width * 1.4)
        }
        .clipped()
        .onAppear {
            guard !reduceMotion, !Eclipse.uiTesting else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// Cards that respond to touch with a gentle press.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    /// iOS 18 zoom transition from a library cover into its series page; plain push on iOS 17.
    @ViewBuilder func zoomSource(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { self.matchedTransitionSource(id: id, in: namespace) } else { self }
    }
    @ViewBuilder func zoomDestination(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { self.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}

extension View {
    /// Gentle breathing pulse for loading marks (off with Reduce Motion).
    func symbolEffectPulse() -> some View { modifier(PulseModifier()) }
}
private struct PulseModifier: ViewModifier {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.06 : 0.94)
            .opacity(on ? 1 : 0.7)
            .onAppear {
                guard !reduceMotion, !Eclipse.uiTesting else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
