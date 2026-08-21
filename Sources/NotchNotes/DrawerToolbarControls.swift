import SwiftUI

struct SettingsMenu: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var isHovering = false

    var body: some View {
        Menu {
            Text("Open NotchNotes · \(settingsStore.triggerMode.title)")

            ForEach(TriggerMode.allCases) { mode in
                Button {
                    settingsStore.triggerMode = mode
                } label: {
                    Label(
                        mode.title,
                        systemImage: settingsStore.triggerMode == mode
                            ? "checkmark"
                            : mode.systemImage
                    )
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 0.88 : 0.76))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.085 : 0.055))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.white.opacity(0.76))
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

struct KeepAwakeButton: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var steamBurstID = 0

    var body: some View {
        Button {
            settingsStore.toggleKeepAwake()
        } label: {
            ZStack {
                Image(systemName: settingsStore.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")

                if steamBurstID > 0 {
                    CoffeeSteamBurst()
                        .id(steamBurstID)
                        .offset(y: -12)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeepAwakeButtonStyle(isActive: settingsStore.isKeepingAwake))
        .disabled(settingsStore.isChangingKeepAwake)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityValue(settingsStore.isKeepingAwake ? "On" : "Off")
        .onChange(of: settingsStore.isKeepingAwake) { oldValue, newValue in
            if !oldValue, newValue, !reduceMotion {
                steamBurstID += 1
            }
        }
        .alert(
            "Couldn’t Keep Mac Awake",
            isPresented: Binding(
                get: { settingsStore.keepAwakeErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        settingsStore.dismissKeepAwakeError()
                    }
                }
            )
        ) {
            Button("OK") {
                settingsStore.dismissKeepAwakeError()
            }
        } message: {
            Text(settingsStore.keepAwakeErrorMessage ?? "")
        }
    }

    private var helpText: String {
        if settingsStore.isChangingKeepAwake {
            return "Changing keep-awake mode…"
        }
        return settingsStore.isKeepingAwake
            ? "Stop keeping Mac awake"
            : "Keep Mac awake, even with the lid closed"
    }
}

private struct CoffeeSteamBurst: View {
    var body: some View {
        HStack(spacing: 0.5) {
            CoffeeSteamTrail(delay: 0, bend: -1.15, drift: -0.75, height: 10)
            CoffeeSteamTrail(delay: 0.07, bend: 1.05, drift: 0.25, height: 12)
            CoffeeSteamTrail(delay: 0.14, bend: -0.9, drift: 0.75, height: 9)
        }
        .frame(width: 18, height: 14, alignment: .bottom)
    }
}

private struct CoffeeSteamTrail: View {
    let delay: Double
    let bend: CGFloat
    let drift: CGFloat
    let height: CGFloat

    @State private var progress: CGFloat = 0
    @State private var trailOpacity = 0.0

    var body: some View {
        CoffeeSteamCurve(bend: bend)
            .trim(from: max(0, progress - 0.52), to: progress)
            .stroke(
                .white.opacity(0.94),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 4.5, height: height)
            .opacity(trailOpacity)
            .offset(
                x: drift * progress,
                y: 4 - (10 * progress)
            )
            .task {
                do {
                    try await Task.sleep(for: .seconds(delay))

                    withAnimation(.easeOut(duration: 0.16)) {
                        trailOpacity = 0.94
                    }
                    withAnimation(.easeOut(duration: 0.8)) {
                        progress = 1
                    }

                    try await Task.sleep(for: .milliseconds(380))

                    withAnimation(.easeIn(duration: 0.34)) {
                        trailOpacity = 0
                    }
                } catch {
                    trailOpacity = 0
                }
            }
    }
}

private struct CoffeeSteamCurve: Shape {
    let bend: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX + bend, y: rect.midY),
            control1: CGPoint(x: rect.midX - bend, y: rect.maxY * 0.82),
            control2: CGPoint(x: rect.midX + (bend * 1.35), y: rect.maxY * 0.64)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.midX + (bend * 0.65), y: rect.maxY * 0.34),
            control2: CGPoint(x: rect.midX - bend, y: rect.maxY * 0.18)
        )
        return path
    }
}
