import AppKit
import SwiftUI

struct CompactNotchView: View {
    let layout: NotchLayout
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var isHoveringActivationArea = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Color.clear

                    if settingsStore.triggerMode == .click,
                       isHoveringActivationArea {
                        Capsule()
                            .fill(.white.opacity(0.72))
                            .frame(width: 48, height: 2)
                            .shadow(color: .white.opacity(0.32), radius: 4)
                            .padding(.bottom, 1)
                            .transition(.opacity.combined(with: .scale(scale: 0.82)))
                    }
                }
                .frame(width: activationSize.width, height: activationSize.height)
                .contentShape(Rectangle())
                .onHover { isHoveringActivationArea = $0 }
                .pointingHandCursor()

                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .animation(.easeOut(duration: 0.12), value: isHoveringActivationArea)
    }

    private var activationSize: NSSize {
        NSSize(width: layout.notchSize.width, height: layout.compactSize.height)
    }
}
