import AppKit
import Combine
import NotchCenterKit
import SwiftUI

// MARK: - 每实例设置面板

/// 块齿轮 → SettingPopover 的内容：选来源（本地 / 照片图库）+ 轮播参数 + 显示开关。
///
/// 一律写 `AlbumPlacementModel`（`placementStore` 持久化，多屏副本同步），
/// 不在这里持有任何自己的状态副本；浮卡本身由宿主经 Kit `SettingPopover` 弹出，
/// 插件不自绘浮窗、也不在卡片里再套 ScrollView（外层已是滚动容器）。
struct AlbumSettingsView: View {
    let context: BlockContext

    @ObservedObject private var model: AlbumPlacementModel

    /// 当前在挑哪一类来源。只影响本面板显示哪套选择器，不直接等于当前来源——
    /// 所以下面永远显示一行"当前：…"，避免用户切了 tab 就不知道块里到底在展示什么。
    @State private var usesPhotos: Bool
    @State private var albums: [AlbumAlbumRef] = []
    @State private var albumsLoaded = false
    /// 单张块：正在其中挑图的相册（非 nil = 显示缩略网格）。
    @State private var pickingAlbum: AlbumAlbumRef?
    @State private var assets: [AlbumItemRef] = []
    /// 用户在系统设置里改了权限后切回前台：让状态查询与相册列表重来一遍。
    @State private var activationToken = 0

    /// 单张块挑图时列出的候选数量上限（懒加载缩略图，够翻近期的即可）。
    private static let assetPickLimit = 120
    /// 设置面板里的缩略图目标像素（约 44pt 网格 ×2 背板，取 256 档）。
    private static let thumbnailPixel: CGFloat = 132

    init(context: BlockContext) {
        self.context = context
        // 与块视图取同一个模型实例（注册表按 placementID 去重），所以设置面板里的
        // 改动会立刻反映到块上，多屏副本也是同一份。
        let model = AlbumInstanceRegistry.shared.model(
            placementID: context.placementID,
            blockID: context.blockID,
            stateStore: context.stateStore,
            hostController: context.hostController)
        _model = ObservedObject(wrappedValue: model)
        _usesPhotos = State(initialValue: model.source?.isFromPhotosLibrary ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("settings.section.source")) { sourceSection }
            if model.isCarousel {
                section(L("settings.section.slideshow")) { slideshowSection }
            }
            section(L("settings.section.display")) { displaySection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadKey) {
            guard usesPhotos, photosStatus.isUsable else {
                albums = []
                albumsLoaded = false
                return
            }
            albums = AlbumPhotoAccess.library.albums()
            albumsLoaded = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            activationToken += 1
        }
    }

    private var photosStatus: PermissionStatus {
        context.hostController.permissionStatus(of: .photos)
    }

    /// 相册列表的重取时机：切换来源类型、权限状态变化、以及从系统设置切回前台。
    private var reloadKey: String {
        "\(usesPhotos)|\(photosStatus.rawValue)|\(activationToken)"
    }

    // MARK: 来源

    @ViewBuilder
    private var sourceSection: some View {
        Picker("", selection: $usesPhotos) {
            Text(L("settings.source.local")).tag(false)
            Text(L("settings.source.photos")).tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)

        Text(LF("settings.source.current", currentSourceDescription))
            .font(NotchTokens.Text.system(10))
            .foregroundStyle(NotchTokens.Foreground.muted)
            .lineLimit(2)
            .truncationMode(.middle)

        if usesPhotos {
            photosSection
        } else {
            localSection
        }
    }

    private var currentSourceDescription: String {
        guard let source = model.source else { return L("settings.source.none") }
        if let path = source.localPath { return path }
        if let identifier = source.photosIdentifier,
           let album = albums.first(where: { $0.id == identifier }) {
            return album.title
        }
        return model.captionTitle ?? L("settings.source.photos")
    }

    @ViewBuilder
    private var localSection: some View {
        HStack(spacing: 6) {
            Button(model.isCarousel ? L("settings.source.chooseFolder") : L("settings.source.chooseFile")) {
                chooseLocalSource()
            }
            .buttonStyle(AlbumActionButtonStyle())
            if model.source?.isFromPhotosLibrary == false {
                Button(L("settings.source.clear")) { model.setSource(nil) }
                    .buttonStyle(AlbumActionButtonStyle())
            }
        }
        if model.isCarousel {
            toggleRow(L("settings.source.recursive"), isOn: recursiveBinding)
        }
    }

    private func chooseLocalSource() {
        // 交给 `AlbumLocalPicker`：它负责"非模态 + 抬层级"这两件必须做对的事
        // （见该类型的说明——用 `runModal` 会被我们自己的抽屉/浮窗压住）。
        let isCarousel = model.isCarousel
        AlbumLocalPicker.shared.present(
            choosingDirectory: isCarousel,
            title: isCarousel ? L("settings.source.chooseFolder") : L("settings.source.chooseFile")
        ) { url in
            // 回调触发时设置卡可能已随抽屉收起而消失，所以这里只碰模型（注册表持有它），
            // 不依赖任何视图状态。
            model.setSource(
                isCarousel
                    ? .localFolder(path: url.path)
                    : .localImageFile(path: url.path))
        }
    }

    @ViewBuilder
    private var photosSection: some View {
        if !photosStatus.isUsable {
            permissionGate
        } else if let pickingAlbum, !model.isCarousel {
            assetGrid(for: pickingAlbum)
        } else {
            albumList
        }
    }

    private var permissionGate: some View {
        let denied = photosStatus == .denied || photosStatus == .restricted
        return VStack(alignment: .leading, spacing: 5) {
            Text(denied ? L("gate.photos.denied.title") : L("gate.photos.title"))
                .font(NotchTokens.Text.system(11, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text(denied ? L("gate.photos.denied.message") : L("gate.photos.message"))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("gate.photos.action")) {
                context.hostController.presentPermissions([.photos])
            }
            .buttonStyle(AlbumActionButtonStyle())
            .help(L("gate.photos.action.help"))
        }
    }

    @ViewBuilder
    private var albumList: some View {
        if albumsLoaded, albums.isEmpty {
            Text(L("empty.noAlbums.message"))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(albums) { album in
                    albumRow(album)
                }
            }
        }
    }

    private func albumRow(_ album: AlbumAlbumRef) -> some View {
        let isCurrent = model.source?.photosIdentifier == album.id
        return Button {
            if model.isCarousel {
                model.setSource(.photosAlbum(identifier: album.id))
            } else {
                // 单张块：先选相册，再在缩略网格里挑具体一张。
                pickingAlbum = album
                assets = AlbumPhotoAccess.library.items(
                    inAlbum: album.id, limit: Self.assetPickLimit)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: album.isSmart ? "sparkles" : "rectangle.stack")
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .frame(width: 14)
                Text(album.title)
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.hover)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let count = album.assetCount {
                    Text(LF("settings.album.count", count))
                        .font(NotchTokens.Text.system(9))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(NotchTokens.Text.system(10, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.selected)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background {
                RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                    .fill(isCurrent ? NotchTokens.Surface.fillHighlighted : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func assetGrid(for album: AlbumAlbumRef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    pickingAlbum = nil
                    assets = []
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(NotchTokens.Text.system(9, weight: .semibold))
                        Text(L("settings.assetPick.back"))
                            .font(NotchTokens.Text.system(10, weight: .medium))
                    }
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                }
                .buttonStyle(.plain)
                Text(album.title)
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(L("settings.assetPick.hint"))
                .font(NotchTokens.Text.system(9))
                .foregroundStyle(NotchTokens.Foreground.disabled)

            if assets.isEmpty {
                Text(L("settings.assetPick.empty"))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 44), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(assets) { item in
                        AlbumAssetThumbnail(
                            item: item,
                            maxPixel: Self.thumbnailPixel,
                            isSelected: model.source?.photosIdentifier == item.identifier
                        ) {
                            model.setSource(.photosAsset(identifier: item.identifier))
                        }
                    }
                }
            }
        }
    }

    // MARK: 轮播

    @ViewBuilder
    private var slideshowSection: some View {
        row(L("settings.interval")) {
            Picker("", selection: intervalBinding) {
                ForEach(AlbumIntervals.allowed, id: \.self) { seconds in
                    Text(LF("settings.interval.value", Int(seconds))).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        row(L("settings.order")) {
            Picker("", selection: randomOrderBinding) {
                Text(L("settings.order.sequential")).tag(false)
                Text(L("settings.order.random")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    // MARK: 显示

    @ViewBuilder
    private var displaySection: some View {
        toggleRow(L("settings.fillsFrame"), isOn: fillsFrameBinding)
        toggleRow(L("settings.showsCaption"), isOn: showsCaptionBinding)
    }

    // MARK: 绑定

    private var recursiveBinding: Binding<Bool> {
        Binding(get: { model.carouselConfig.recursive }, set: { model.setRecursive($0) })
    }

    private var fillsFrameBinding: Binding<Bool> {
        Binding(get: { model.fillsFrame }, set: { model.setFillsFrame($0) })
    }

    private var showsCaptionBinding: Binding<Bool> {
        Binding(get: { model.showsCaption }, set: { model.setShowsCaption($0) })
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { model.carouselConfig.intervalSeconds },
            set: { model.setInterval($0) })
    }

    private var randomOrderBinding: Binding<Bool> {
        Binding(
            get: { model.carouselConfig.randomOrder },
            set: { model.setRandomOrder($0) })
    }

    // MARK: 版式小件（与官方插件设置面板同档）

    private func row<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.muted)
            content()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(NotchTokens.Text.toolbarSmall)
                .foregroundStyle(NotchTokens.Foreground.secondary)
            content()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.hover)
        }
        .controlSize(.small)
    }
}

// MARK: - 设置面板里的资产缩略图

/// 设置面板里的一个可选缩略图。图片走与块内同一条取图管线（同一份缓存），
/// 所以"刚在设置里挑过的那张"回到块里显示时不需要再解一次。
private struct AlbumAssetThumbnail: View {
    let item: AlbumItemRef
    let maxPixel: CGFloat
    let isSelected: Bool
    let onTap: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            AlbumPalette.placeholder
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.thumbnail, style: .continuous)
                .strokeBorder(
                    isSelected ? NotchTokens.Hairline.chipSelected : NotchTokens.Hairline.thumbnail,
                    lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: item.id) {
            image = await AlbumImageLoader.image(for: item, maxPixel: maxPixel)
        }
        .help(item.title ?? L("caption.photos"))
        .accessibilityLabel(item.title ?? L("caption.photos"))
    }
}
