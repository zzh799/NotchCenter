import AppKit
import Foundation
import NotchCenterKit

// MARK: - 块状态

/// 一块相册块当下要画成什么。降级态是**一等公民**：来源没配、权限没给、
/// 文件夹被 TCC 挡住、图库里的照片被删，都各有各的呈现，绝不抛错、绝不整块消失。
enum AlbumLoadState: Equatable, Sendable {
    /// 还没选来源。
    case unconfigured
    /// 图库来源但授权不可用（带去重的当前状态，引导语据此分叉）。
    case photosPermission(PermissionStatus)
    case loading
    /// 就绪，关联值为可显示的图张数。
    case ready(Int)
    /// 来源可用，但没有可显示的图。
    case empty
    /// 来源不在原位（文件夹/文件被移走，或图库里的资产已被删除）。
    case missingSource
    /// 目录存在但读不出来（macOS 拒绝了访问）。
    case unreadable
}

// MARK: - 每实例模型

/// 一个块摆放实例的运行期模型。
///
/// **一个实例一个模型**：同一份块视图会被宿主放进每块屏的抽屉树（多屏 = 多份
/// 视图副本），设置浮卡又可能同时编辑同一实例，所以状态必须收敛到按 placementID
/// 注册的唯一 `ObservableObject`（`AlbumInstanceRegistry`），所有副本观察同一对象。
///
/// **轮播定时器归模型、不归视图**：视图只用 `setViewer(id:visible:)` 登记"我这个
/// 副本此刻是不是看得见"。抽屉温存（收起不卸载，见决策 2026-09-11-drawer-content-warmth）
/// 让 `onDisappear` 不再等于"看不见"，所以停表必须由 `\.isDrawerPresented` 驱动；
/// 视图放 `@State` 定时器会在多屏各推一次，收起后还会空转。
@MainActor
final class AlbumPlacementModel: ObservableObject {
    let placementID: String
    let blockID: String

    @Published private(set) var carouselConfig: CarouselConfig
    @Published private(set) var photoConfig: PhotoConfig

    @Published private(set) var loadState: AlbumLoadState = .unconfigured
    @Published private(set) var items: [AlbumItemRef] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var currentImage: NSImage?
    /// 当前这张取不到图（文件坏了、被删了、相册里那张没了）。与 `loadState`
    /// 分开：轮播里坏了一张不该把整块降级，画一张降级卡、控制条照常可用，
    /// 用户能自己跳到下一张。
    @Published private(set) var isCurrentItemFailed = false
    @Published private(set) var isPaused = false
    /// 来源的显示名（文件夹名 / 相册名 / 文件名），说明带与设置面板共用。
    @Published private(set) var sourceTitle: String?

    private let store: StateStore?
    private weak var hostController: (any HostController)?

    /// 当前"看得见"的视图副本。空集 = 没有任何一份在屏，定时器必须停。
    private var visibleViewers: Set<UUID> = []
    private var displaySize: CGSize = .zero
    private var displayScale: CGFloat = 2

    private var loadTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var timerInterval: Double?

    private var shuffleCursor = AlbumShuffleCursor()
    private var randomGenerator = SystemRandomNumberGenerator()

    init(placementID: String, blockID: String, store: StateStore?) {
        self.placementID = placementID
        self.blockID = blockID
        self.store = store
        self.carouselConfig = AlbumConfigLogic.loadCarousel(from: store)
        self.photoConfig = AlbumConfigLogic.loadPhoto(from: store)
    }

    // MARK: 派生

    var isCarousel: Bool { blockID == AlbumBlock.carousel }

    var source: AlbumSource? { isCarousel ? carouselConfig.source : photoConfig.source }

    var fillsFrame: Bool { isCarousel ? carouselConfig.fillsFrame : photoConfig.fillsFrame }

    var showsCaption: Bool { isCarousel ? carouselConfig.showsCaption : photoConfig.showsCaption }

    var currentItem: AlbumItemRef? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// 说明带标题：优先当前图自己的名字（本地文件），其次来源名（文件夹/相册）。
    var captionTitle: String? {
        currentItem?.title ?? sourceTitle
    }

    /// 轮播位置（从 1 开始计），单张块或只有一张时为 nil。
    var captionPosition: (index: Int, count: Int)? {
        guard isCarousel, items.count > 1, items.indices.contains(currentIndex) else { return nil }
        return (currentIndex + 1, items.count)
    }

    var canAdvance: Bool { items.count > 1 }

    private var maxDisplayPixel: CGFloat {
        // 尺寸还没上报时给一个够用的默认值，免得先按 1px 解一张糊图进缓存。
        guard displaySize.width > 0, displaySize.height > 0 else { return 512 }
        return max(displaySize.width, displaySize.height) * displayScale
    }

    // MARK: 宿主注入与生命周期

    func attach(hostController: any HostController) {
        self.hostController = hostController
    }

    /// 实例被移除 / 插件被停用：停掉所有在跑的活，避免留一个后台任务给已消失的块解码。
    func prepareForRemoval() {
        visibleViewers.removeAll()
        loadTask?.cancel()
        imageTask?.cancel()
        timerTask?.cancel()
        timerTask = nil
        timerInterval = nil
    }

    // MARK: 回归测试可见性

    /// 定时器当下是否在跑。只读暴露给回归测试（同 `CameraStore.isConfigured` 的口径）：
    /// 抽屉收起、只有一张图、用户暂停、没有来源时都必须是 false。
    var isTimerRunning: Bool { timerTask != nil }

    /// 等当前这一轮枚举落地。生产路径不需要等（结果自己会推给视图），单测需要它把
    /// "刚配置完"与"状态已就位"对齐。
    func awaitPendingLoad() async {
        guard let task = loadTask else { return }
        await task.value
    }

    /// 等当前这张图的解码/请求落地（含随后的下一张预热）。同样只服务单测。
    func awaitPendingImage() async {
        guard let task = imageTask else { return }
        await task.value
    }

    // MARK: 视图登记（可见性 = 定时器的唯一开关）

    /// 视图副本每次"可见性"变化都调这里；`Set` 语义天然幂等，收起与卸载先后触发也不会错乱。
    func setViewer(id: UUID, visible: Bool) {
        let wasEmpty = visibleViewers.isEmpty
        if visible {
            visibleViewers.insert(id)
        } else {
            visibleViewers.remove(id)
        }
        let isNowEmpty = visibleViewers.isEmpty
        syncTimer()
        // 从"没有任何副本在屏"变为"有副本在屏" = 用户刚展开抽屉：重新枚举来源，
        // 让期间新增/删除的照片立刻反映出来（我们不接 PHPhotoLibrary 变更观察者）。
        if wasEmpty, !isNowEmpty { reload() }
    }

    func setDisplaySize(_ size: CGSize, scale: CGFloat) {
        guard size != displaySize || scale != displayScale else { return }
        let oldBucket = AlbumImageKey.bucket(forPixel: maxDisplayPixel)
        displaySize = size
        displayScale = scale > 0 ? scale : 2
        // 只在跨档位时重解：拖拽缩放会让尺寸连续变化，每 1pt 都重解一次是浪费。
        if AlbumImageKey.bucket(forPixel: maxDisplayPixel) != oldBucket {
            loadCurrentImage()
        }
    }

    /// 清掉当前图与它的失败标记。两件事必须成对发生，否则会留下"图没了但还标着失败"
    /// 的中间态，视图会画出错误的降级提示。
    private func clearCurrentImage() {
        currentImage = nil
        isCurrentItemFailed = false
    }

    // MARK: 播放控制

    func next() { moveForward(userInitiated: true) }

    func previous() { moveBackward(userInitiated: true) }

    func togglePause() {
        isPaused.toggle()
        syncTimer()
    }

    /// 手动刷新：忘记失败缓存（文件可能已经回来了）并重新枚举。
    func refresh() {
        AlbumImageCache.shared.forgetFailures()
        reload()
    }

    // MARK: 配置写入

    func setSource(_ source: AlbumSource?) {
        guard let sanitized = AlbumConfigLogic.sanitize(source: source, forBlock: blockID) else {
            applySource(nil)
            return
        }
        applySource(sanitized)
    }

    private func applySource(_ source: AlbumSource?) {
        if isCarousel {
            var next = carouselConfig
            next.source = source
            carouselConfig = next
            AlbumConfigLogic.save(next, to: store)
        } else {
            var next = photoConfig
            next.source = source
            photoConfig = next
            AlbumConfigLogic.save(next, to: store)
        }
        // 换来源等于换了一整套图：清掉失败缓存并回到第一张。
        AlbumImageCache.shared.forgetFailures()
        items = []
        currentIndex = 0
        clearCurrentImage()
        shuffleCursor.reset(count: 0, previous: nil, using: &randomGenerator)
        reload()
    }

    func setInterval(_ seconds: Double) {
        guard isCarousel else { return }
        var next = carouselConfig
        next.intervalSeconds = AlbumConfigLogic.sanitizeInterval(seconds)
        carouselConfig = next
        AlbumConfigLogic.save(next, to: store)
        syncTimer()
    }

    func setRandomOrder(_ on: Bool) {
        guard isCarousel else { return }
        var next = carouselConfig
        next.randomOrder = on
        carouselConfig = next
        AlbumConfigLogic.save(next, to: store)
        shuffleCursor.reset(count: items.count, previous: currentIndex, using: &randomGenerator)
    }

    func setRecursive(_ on: Bool) {
        guard isCarousel, carouselConfig.recursive != on else { return }
        var next = carouselConfig
        next.recursive = on
        carouselConfig = next
        AlbumConfigLogic.save(next, to: store)
        reload()
    }

    func setFillsFrame(_ on: Bool) {
        if isCarousel {
            var next = carouselConfig
            next.fillsFrame = on
            carouselConfig = next
            AlbumConfigLogic.save(next, to: store)
        } else {
            var next = photoConfig
            next.fillsFrame = on
            photoConfig = next
            AlbumConfigLogic.save(next, to: store)
        }
    }

    func setShowsCaption(_ on: Bool) {
        if isCarousel {
            var next = carouselConfig
            next.showsCaption = on
            carouselConfig = next
            AlbumConfigLogic.save(next, to: store)
        } else {
            var next = photoConfig
            next.showsCaption = on
            photoConfig = next
            AlbumConfigLogic.save(next, to: store)
        }
    }

    // MARK: 枚举来源

    /// 重新枚举来源并（尽量）保持当前那张不变。抽屉每次展开、换来源、点刷新都会走到这里。
    func reload() {
        guard let source else {
            loadTask?.cancel()
            loadTask = nil
            items = []
            currentIndex = 0
            clearCurrentImage()
            sourceTitle = nil
            loadState = .unconfigured
            syncTimer()
            return
        }

        if source.isFromPhotosLibrary {
            let status = hostController?.permissionStatus(of: .photos) ?? .notDetermined
            guard status.isUsable else {
                loadTask?.cancel()
                loadTask = nil
                items = []
                currentIndex = 0
                clearCurrentImage()
                loadState = .photosPermission(status)
                syncTimer()
                return
            }
        }

        loadTask?.cancel()
        loadState = .loading
        let recursive = carouselConfig.recursive
        loadTask = Task { [weak self] in
            let outcome = await AlbumSourceLoader.enumerate(source: source, recursive: recursive)
            guard let self, !Task.isCancelled else { return }
            self.apply(outcome: outcome)
        }
    }

    private func apply(outcome: AlbumSourceLoader.Outcome) {
        let previous = currentItem

        switch outcome {
        case let .items(newItems, title):
            items = newItems
            sourceTitle = title
            if newItems.isEmpty {
                currentIndex = 0
                clearCurrentImage()
                loadState = .empty
            } else {
                // 重枚举后当前那张还在就留在原地：否则每次展开抽屉都会跳回第一张。
                if let previous, let kept = newItems.firstIndex(of: previous) {
                    currentIndex = kept
                } else {
                    currentIndex = 0
                }
                loadState = .ready(newItems.count)
                shuffleCursor.reset(
                    count: newItems.count, previous: currentIndex, using: &randomGenerator)
                loadCurrentImage()
            }
        case .empty:
            items = []
            currentIndex = 0
            clearCurrentImage()
            loadState = .empty
        case .missingSource:
            items = []
            currentIndex = 0
            clearCurrentImage()
            sourceTitle = nil
            loadState = .missingSource
        case .unreadable:
            items = []
            currentIndex = 0
            clearCurrentImage()
            loadState = .unreadable
        }

        syncTimer()
    }

    // MARK: 取图

    /// 预取下一张用的：随机模式下真正的下一张要等推进那一刻才知道，这里按顺序取一张。
    private func previewItem(after item: AlbumItemRef) -> AlbumItemRef? {
        guard items.count > 1, let index = items.firstIndex(of: item) else { return nil }
        return items[AlbumOrder.nextSequential(after: index, count: items.count)]
    }

    private func loadCurrentImage() {
        guard let item = currentItem else {
            imageTask?.cancel()
            imageTask = nil
            clearCurrentImage()
            return
        }
        let maxPixel = maxDisplayPixel
        imageTask?.cancel()
        isCurrentItemFailed = false
        imageTask = Task { [weak self] in
            let image = await AlbumImageLoader.image(for: item, maxPixel: maxPixel)
            guard let self, !Task.isCancelled else { return }
            // 期间可能已经切到别的图：只认"还是当前这张"的结果，避免旧图覆盖新图。
            if self.currentItem == item {
                self.currentImage = image
                self.isCurrentItemFailed = image == nil
            }
            guard !Task.isCancelled, let next = self.previewItem(after: item) else { return }
            await AlbumImageLoader.prefetch(next, maxPixel: maxPixel)
        }
    }

    // MARK: 推进

    private func moveForward(userInitiated: Bool) {
        guard canAdvance else { return }
        if isCarousel, carouselConfig.randomOrder {
            currentIndex = shuffleCursor.next(
                count: items.count, current: currentIndex, using: &randomGenerator)
        } else {
            currentIndex = AlbumOrder.nextSequential(after: currentIndex, count: items.count)
        }
        if userInitiated { syncTimer() }
        loadCurrentImage()
    }

    private func moveBackward(userInitiated: Bool) {
        guard canAdvance else { return }
        currentIndex = AlbumOrder.previousSequential(before: currentIndex, count: items.count)
        if userInitiated { syncTimer() }
        loadCurrentImage()
    }

    // MARK: 定时器

    private var isTimerActive: Bool {
        isCarousel && !visibleViewers.isEmpty && !isPaused && canAdvance
    }

    /// 定时器的唯一开关。间隔变了会重启（否则新间隔要等当前这一觉睡完才生效），
    /// 其它情况保持不动——改个"显示说明"不该把轮播计时清零。
    private func syncTimer() {
        guard isTimerActive else {
            timerTask?.cancel()
            timerTask = nil
            timerInterval = nil
            return
        }
        if let task = timerTask, !task.isCancelled,
           timerInterval == carouselConfig.intervalSeconds {
            return
        }
        timerTask?.cancel()
        timerInterval = carouselConfig.intervalSeconds
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.carouselConfig.intervalSeconds else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard self.isTimerActive else { continue }
                self.moveForward(userInitiated: false)
            }
        }
    }
}

// MARK: - 枚举来源（IO 封装）

/// 把"来源 → 一组图"的四种 IO（目录扫描、单文件探活、相册取资产、单资产探活）
/// 收在一处，让模型只管状态机。
@MainActor
enum AlbumSourceLoader {
    enum Outcome: Equatable {
        case items([AlbumItemRef], title: String?)
        case empty
        case missingSource
        case unreadable
    }

    static func enumerate(source: AlbumSource, recursive: Bool) async -> Outcome {
        switch source {
        case let .localFolder(path):
            let outcome = await Task.detached(priority: .userInitiated) {
                AlbumFolderScan.scan(folderPath: path, recursive: recursive)
            }.value
            switch outcome {
            case let .found(items):
                let title = (path as NSString).lastPathComponent
                return items.isEmpty ? .empty : .items(items, title: title)
            case .missing:
                return .missingSource
            case .unreadable:
                return .unreadable
            }

        case let .localImageFile(path):
            let state = await Task.detached(priority: .userInitiated) {
                AlbumFileProbe.state(ofFileAt: path)
            }.value
            guard state == .ready else { return .missingSource }
            let name = (path as NSString).lastPathComponent
            return .items([AlbumItemRef.localFile(path: path, title: name)], title: name)

        case let .photosAlbum(identifier):
            let library = AlbumPhotoAccess.library
            guard let title = library.albumTitle(forIdentifier: identifier) else {
                return .missingSource
            }
            let items = library.items(
                inAlbum: identifier, limit: AlbumPhotoLibrary.maxAssetsPerAlbum)
            return items.isEmpty ? .empty : .items(items, title: title)

        case let .photosAsset(identifier):
            guard let item = AlbumPhotoAccess.library.asset(identifier: identifier) else {
                return .missingSource
            }
            // 图库资产没有文件名，说明带上用拍摄日期代替（取不到就留空，不编一个假的）。
            let title = item.capturedAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
            return .items([item], title: title)
        }
    }
}

// MARK: - 进程内注册表

@MainActor
final class AlbumInstanceRegistry {
    static let shared = AlbumInstanceRegistry()

    private var models: [String: AlbumPlacementModel] = [:]

    /// 取（或创建）某摆放实例的共享模型；`stateStore` 为插件级共享存储，
    /// 内部派生该实例的 `placementStore`。
    func model(
        placementID: String,
        blockID: String,
        stateStore: StateStore,
        hostController: any HostController
    ) -> AlbumPlacementModel {
        if let model = models[placementID] {
            model.attach(hostController: hostController)
            return model
        }
        let model = AlbumPlacementModel(
            placementID: placementID,
            blockID: blockID,
            store: stateStore.placementScope(placementID: placementID))
        model.attach(hostController: hostController)
        models[placementID] = model
        return model
    }

    /// 实例被移除：停活并丢弃内存模型（持久化配置由插件入口清）。
    func discard(placementID: String) {
        models.removeValue(forKey: placementID)?.prepareForRemoval()
    }

    /// 插件被停用：所有实例一起停。
    func discardAll() {
        for model in models.values { model.prepareForRemoval() }
        models.removeAll()
    }
}
