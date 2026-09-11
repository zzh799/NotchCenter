import AppKit
import NotchCenterKit
import SwiftUI

/// 抽屉块 `lidangle.console` 的布局常量。
///
/// **探针与视图必须共用这一组常量**(插件开发指南 §3「探针语义 = 意图契约」),
/// 改版式时两边一起改,否则 `verify-sizes` 会在最小尺寸下报越界/自叠。
enum LidConsoleMetrics {
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 8

    /// 顶栏:标题 + 开关。
    static let headerHeight: CGFloat = 20
    /// 角度读数区:大号角度数字 + 状态胶囊。
    static let readoutHeight: CGFloat = 46
    /// 透视示意条:随盖角收缩的画面比例条。
    static let gaugeHeight: CGFloat = 18
    /// 底部动作行:试播效果 + 权限/诊断。
    static let actionHeight: CGFloat = 24

    /// 内容区宽度(块物理宽度减去左右内边距)。
    static func contentWidth(for size: CGSize) -> CGFloat {
        max(size.width - inset * 2, 0)
    }

    /// 自上而下各条带的 y 起点。与 `body` 的 `VStack` 顺序一一对应。
    static func bandOrigins(for size: CGSize) -> [CGFloat] {
        var y = inset
        var origins: [CGFloat] = []
        for height in [headerHeight, readoutHeight, gaugeHeight, actionHeight] {
            origins.append(y)
            y += height + spacing
        }
        return origins
    }
}

/// 合盖效果的控制台块。
///
/// 效果本身是全屏覆盖窗,不在刘海里;这个块是它的**仪表盘与控制面**:实时盖角、
/// 合盖状态、总开关、以及不动机器也能看的「试播效果」。
struct LidConsoleBlockView: View {
    let context: BlockContext
    @ObservedObject var controller: LidDepthController
    @ObservedObject var preferences: LidDepthPreferences

    var body: some View {
        let size = context.layoutInfo.frame.size
        let origins = LidConsoleMetrics.bandOrigins(for: size)

        return VStack(alignment: .leading, spacing: LidConsoleMetrics.spacing) {
            header
                .frame(height: LidConsoleMetrics.headerHeight, alignment: .leading)
            readout
                .frame(height: LidConsoleMetrics.readoutHeight, alignment: .leading)
            gauge
                .frame(height: LidConsoleMetrics.gaugeHeight)
            actionRow
                .frame(height: LidConsoleMetrics.actionHeight, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(LidConsoleMetrics.inset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("a11y.console"))
    }

    // MARK: 条带

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                .font(NotchTokens.Text.system(12, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(L("block.console.title"))
                .font(NotchTokens.Text.system(12, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.body)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { preferences.isEnabled },
                set: { preferences.isEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!controller.isSensorAvailable)
            .focusable(false)
            .focusEffectDisabled(true)
            .accessibilityLabel(L("a11y.enable"))
        }
    }

    @ViewBuilder
    private var readout: some View {
        if !controller.isSensorAvailable {
            // 降级态:机型不支持传感器。整块仍然可用(设置与说明都在),只是没有读数。
            VStack(alignment: .leading, spacing: 2) {
                Text(L("console.unsupported.title"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Semantic.unavailable)
                Text(L("console.unsupported.detail"))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(LF("console.angle", Int(controller.currentAngle.rounded())))
                        .font(NotchTokens.Text.system(26, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchTokens.Foreground.body)
                        .monospacedDigit()
                    Text(L("console.degrees"))
                        .font(NotchTokens.Text.system(11))
                        .foregroundStyle(NotchTokens.Foreground.muted)
                    Spacer(minLength: 4)
                    stateChip
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stateChip: some View {
        let (text, tint): (String, Color) = {
            if controller.isPlayingEffect { return (L("console.state.effect"), NotchTokens.Semantic.accentGreen) }
            switch controller.lidState {
            case .closed: return (L("console.state.closed"), NotchTokens.Foreground.secondary)
            case .closing: return (L("console.state.closing"), NotchTokens.Semantic.unavailable)
            case .open: return (L("console.state.open"), NotchTokens.Foreground.muted)
            }
        }()
        return Text(text)
            .font(NotchTokens.Text.system(10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                    .fill(NotchTokens.Surface.fill)
            )
    }

    /// 透视示意条:一条随盖角在纵向上收缩的条,让用户在小尺寸下也能看见透视在发生什么。
    /// 收缩比与真实效果同源(`DepthGeometry.verticalCompression`)。
    private var gauge: some View {
        GeometryReader { proxy in
            let frame = proxy.size
            let compression = previewCompression
            let barHeight = max(frame.height * compression, 2)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(NotchTokens.Surface.track)
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(NotchTokens.Surface.fillHighlighted)
                    .frame(height: barHeight)
            }
        }
        .accessibilityHidden(true)
    }

    /// 用当前参数算出的纵向压缩比(1 = 没透视,越小越"压扁")。
    private var previewCompression: Double {
        let screenSize = NSScreen.builtIn?.frame.size ?? CGSize(width: 1512, height: 982)
        let start = preferences.thresholdAngle
        // 读数缺失(传感器不可用)时按"全开"画,示意条保持满高而不是塌成一条线。
        let current = controller.isSensorAvailable ? controller.currentAngle : start
        let geometry = DepthGeometry()
        return geometry.verticalCompression(
            startAngle: start,
            currentAngle: current,
            viewingDistanceRatio: preferences.viewingDistance,
            recession: preferences.recession,
            screenSize: screenSize
        )
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            Button {
                // 缺屏幕录制权限时试播只会演一遍空白:先把权限弹窗摆出来,
                // 而不是让用户对着没反应的效果猜。
                if controller.hasScreenCapturePermission {
                    controller.runPreview()
                } else {
                    requestScreenPermission()
                }
            } label: {
                Text(L("console.preview"))
                    .font(NotchTokens.Text.system(11, weight: .semibold))
                    .foregroundStyle(canPreview ? NotchTokens.Foreground.selected : NotchTokens.Foreground.disabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                            .fill(NotchTokens.Surface.fill)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled(true)
            .disabled(!canPreview)
            .help(L("console.preview.help"))

            Spacer(minLength: 4)

            if controller.isSensorAvailable, !controller.hasScreenCapturePermission {
                // 缺屏幕录制权限:画面档(实时流与单帧同源同权限)整个停摆,但盖角读数、
                // 状态与开关照常。块内的唯一入口是宿主的权限弹窗,插件不代开系统设置。
                Button(action: requestScreenPermission) {
                    Text(L("console.grant"))
                        .font(NotchTokens.Text.system(9, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.body)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                                .fill(NotchTokens.Surface.fillHighlighted)
                        )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled(true)
                .help(L("console.grant.help"))
            } else if !controller.isStreaming, preferences.isLivePicture {
                // 实时档声明了却没跑起来:多半是流启动失败(权限在,但抓帧出错)。
                Text(L("console.degraded"))
                    .font(NotchTokens.Text.system(9))
                    .foregroundStyle(NotchTokens.Semantic.unavailable)
                    .lineLimit(1)
            }
        }
    }

    private func requestScreenPermission() {
        context.hostController.presentPermissions([.screenRecording])
    }

    private var canPreview: Bool {
        controller.isSensorAvailable && !controller.isPlayingEffect
    }
}
