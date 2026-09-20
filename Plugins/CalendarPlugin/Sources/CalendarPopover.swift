import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 打开日历.app

@MainActor
enum CalendarAppLauncher {
    /// 日历.app 的 bundle id（`com.apple.iCal`）。
    static let bundleIdentifier = "com.apple.iCal"

    /// 经 `NSWorkspace` 打开日历.app。按 bundle id 解析路径而不硬编码
    /// `/System/Applications`（系统位置与版本无关性）；解析失败时退回
    /// `ical://` URL 方案，保证点击始终有反应。
    static func open() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(appURL)
            return
        }
        if let fallback = URL(string: "ical://") {
            NSWorkspace.shared.open(fallback)
        }
    }
}

// MARK: - 长按浮窗

/// 浮窗内容：今日的公历短日期 + 星期 + 干支农历。块内空间只够放「9月｜农历」，
/// 完整信息在此展开。
struct CalendarPopoverContentView: View {
    let snapshot: CalendarMonthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.shortDate)
                .font(NotchTokens.Text.system(13, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.body)
            Text(snapshot.weekdayName)
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(snapshot.lunarFullName)
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(NotchTokens.Hairline.divider)
                .frame(height: 1)
            Text(L("calendar.popover.hint"))
                .font(NotchTokens.Text.system(9))
                .foregroundStyle(NotchTokens.Foreground.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: 浮窗入口

@MainActor
enum CalendarPopover {
    /// 理想卡片尺寸；实际尺寸再夹进「块尺寸 − `BlockPopover.cardInset`」，
    /// 否则卡片伸出块矩形后收不到鼠标、光标一离开停留区抽屉就收起。
    static let idealCardSize = CGSize(width: 132, height: 108)

    static func present(
        snapshot: CalendarMonthSnapshot,
        blockSize: CGSize,
        frameInWindow: CGRect
    ) {
        let limit = CGSize(
            width: max(blockSize.width - BlockPopover.cardInset, 0),
            height: max(blockSize.height - BlockPopover.cardInset, 0))
        let cardSize = CGSize(
            width: min(idealCardSize.width, limit.width),
            height: min(idealCardSize.height, limit.height))
        BlockPopover.shared.present(anchoredTo: frameInWindow, cardSize: cardSize) {
            CalendarPopoverContentView(snapshot: snapshot)
        }
    }
}
