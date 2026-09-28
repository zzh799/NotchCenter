import CoreGraphics
import NotchCenterKit
import XCTest
@testable import AlbumPlugin

// MARK: - 实例模型（可见性驱动的定时器、状态机、注册表）
//
// **隔离纪律**：图库读取口换成假实现，本套件绝不触碰真 PhotoKit，也就绝不会
// 触发系统授权弹窗；本地来源只用临时目录里的空文件。

@MainActor
final class AlbumInstanceTests: XCTestCase {
    private var root: URL!
    private var fakeLibrary: FakePhotoLibrary!
    private var previousLibrary: (any AlbumPhotoLibraryProtocol)!

    // async 版本：`@MainActor` 测试类的同步 setUp 是 nonisolated 的，改不了本类的
    // 隔离属性（`root` / 注入的假图库），async 覆写才会继承类隔离。
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fakeLibrary = FakePhotoLibrary()
        previousLibrary = AlbumPhotoAccess.library
        AlbumPhotoAccess.library = fakeLibrary
    }

    override func tearDown() async throws {
        AlbumPhotoAccess.library = previousLibrary
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: 未配置 / 本地来源

    func testUnconfiguredModelHasNoItemsAndNoTimer() async {
        let model = makeModel()
        await model.awaitPendingLoad()

        XCTAssertEqual(model.loadState, .unconfigured)
        XCTAssertTrue(model.items.isEmpty)
        model.setViewer(id: UUID(), visible: true)
        XCTAssertFalse(model.isTimerRunning, "没有来源就不该有计时")
        model.prepareForRemoval()
    }

    func testLocalFolderLoadsItemsAndKeepsTheCurrentOneAcrossReload() async throws {
        let folder = try makeFolder(named: "carousel", files: ["a.jpg", "b.jpg", "c.jpg"])
        let model = makeModel()
        model.setSource(.localFolder(path: folder.path))
        await model.awaitPendingLoad()

        XCTAssertEqual(model.loadState, .ready(3))
        XCTAssertEqual(model.items.count, 3)
        XCTAssertEqual(model.sourceTitle, "carousel")
        XCTAssertEqual(model.currentIndex, 0)

        model.next()
        XCTAssertEqual(model.currentIndex, 1)

        // 抽屉每次展开都会重枚举；当前那张还在就必须留在原地，否则每次展开都跳回第一张。
        await model.reloadAndWait()
        XCTAssertEqual(model.currentIndex, 1, "重枚举不该丢掉用户正在看的那一张")
        model.prepareForRemoval()
    }

    func testReloadFallsBackToTheFirstItemWhenTheCurrentOneDisappears() async throws {
        let folder = try makeFolder(named: "shrinking", files: ["a.jpg", "b.jpg", "c.jpg"])
        let model = makeModel()
        model.setSource(.localFolder(path: folder.path))
        await model.awaitPendingLoad()
        model.next()
        XCTAssertEqual(model.currentItem?.title, "b.jpg")

        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.jpg"))
        await model.reloadAndWait()

        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.currentItem?.title, "b.jpg", "还在的那张应当继续显示")
        XCTAssertEqual(model.currentIndex, 0)
        model.prepareForRemoval()
    }

    func testMissingLocalFileBecomesMissingSource() async {
        let model = makeModel(blockID: AlbumBlock.photo)
        model.setSource(.localImageFile(path: root.appendingPathComponent("gone.jpg").path))
        await model.awaitPendingLoad()
        XCTAssertEqual(model.loadState, .missingSource)
        model.prepareForRemoval()
    }

    func testSingleItemSourceNeverRunsTheTimer() async throws {
        let folder = try makeFolder(named: "one", files: ["only.jpg"])
        let model = makeModel()
        model.setSource(.localFolder(path: folder.path))
        await model.awaitPendingLoad()

        model.setViewer(id: UUID(), visible: true)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertFalse(model.isTimerRunning, "只有一张时自动推进没有意义")
        XCTAssertFalse(model.canAdvance)
        model.prepareForRemoval()
    }

    // MARK: 定时器随可见性起停

    func testCarouselTimerFollowsViewerVisibility() async throws {
        let folder = try makeFolder(named: "timer", files: ["a.jpg", "b.jpg"])
        let model = makeModel()
        model.setSource(.localFolder(path: folder.path))
        await model.awaitPendingLoad()

        XCTAssertFalse(model.isTimerRunning, "没有任何可见副本时不该跑表")

        let viewer = UUID()
        model.setViewer(id: viewer, visible: true)
        await model.awaitPendingLoad()
        XCTAssertTrue(model.isTimerRunning)

        // 温存让收起不卸载：视图靠这个调用停表，`onDisappear` 靠不住。
        model.setViewer(id: viewer, visible: false)
        XCTAssertFalse(model.isTimerRunning, "抽屉收起必须停表")

        // 重复登记同一份副本（收起与卸载会先后触发）不得把计数弄乱。
        model.setViewer(id: viewer, visible: true)
        model.setViewer(id: viewer, visible: true)
        await model.awaitPendingLoad()
        XCTAssertTrue(model.isTimerRunning)
        model.setViewer(id: viewer, visible: false)
        XCTAssertFalse(model.isTimerRunning)
        model.prepareForRemoval()
    }

    func testPauseStopsTheTimerAndResumeStartsItAgain() async throws {
        let folder = try makeFolder(named: "pause", files: ["a.jpg", "b.jpg"])
        let model = makeModel()
        model.setSource(.localFolder(path: folder.path))
        await model.awaitPendingLoad()
        model.setViewer(id: UUID(), visible: true)
        await model.awaitPendingLoad()
        XCTAssertTrue(model.isTimerRunning)

        model.togglePause()
        XCTAssertTrue(model.isPaused)
        XCTAssertFalse(model.isTimerRunning, "暂停就该停表，而不是继续空转")

        model.togglePause()
        XCTAssertFalse(model.isPaused)
        XCTAssertTrue(model.isTimerRunning)
        model.prepareForRemoval()
    }

    func testAdvancingWrapsAroundAndGoesBackwards() async throws {
        let folder = try makeFolder(named: "wrap", files: ["a.jpg", "b.jpg"])
        let model = makeModel()
        model.setSource(.localFolder(path: folder.path))
        await model.awaitPendingLoad()

        model.next()
        XCTAssertEqual(model.currentIndex, 1)
        model.next()
        XCTAssertEqual(model.currentIndex, 0, "末尾要绕回开头")
        model.previous()
        XCTAssertEqual(model.currentIndex, 1, "开头往回要绕到末尾")
        model.prepareForRemoval()
    }

    // MARK: 图库来源与权限

    func testPhotosSourceWithoutPermissionShowsTheGateAndNeverReadsTheLibrary() async {
        let host = StubHostController()
        host.photosStatus = .notDetermined
        let model = makeModel(host: host)
        model.setSource(.photosAlbum(identifier: "album-1"))
        await model.awaitPendingLoad()

        XCTAssertEqual(model.loadState, .photosPermission(.notDetermined))
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(
            fakeLibrary.albumQueryCount, 0, "没授权就不该去读图库（查询本身也不该发生）")
        model.prepareForRemoval()
    }

    func testDeniedPermissionKeepsTheGateHonest() async {
        let host = StubHostController()
        host.photosStatus = .denied
        let model = makeModel(host: host)
        model.setSource(.photosAlbum(identifier: "album-1"))
        await model.awaitPendingLoad()
        XCTAssertEqual(model.loadState, .photosPermission(.denied))
        model.prepareForRemoval()
    }

    func testPhotosAlbumLoadsItemsAndDecodesThroughTheInjectedLibrary() async {
        let host = StubHostController()
        host.photosStatus = .authorized
        fakeLibrary.albumTitles["album-1"] = "最近项目"
        fakeLibrary.itemsByAlbum["album-1"] = (1...3).map {
            .photosAsset(identifier: "asset-\($0)", capturedAt: nil)
        }

        let model = makeModel(host: host)
        model.setSource(.photosAlbum(identifier: "album-1"))
        await model.awaitPendingLoad()

        XCTAssertEqual(model.loadState, .ready(3))
        XCTAssertEqual(model.sourceTitle, "最近项目")
        await model.awaitPendingImage()
        XCTAssertNotNil(model.currentImage, "图库取图应当经过注入的读取口")
        model.prepareForRemoval()
    }

    func testPhotosAssetThatNoLongerExistsBecomesMissingSource() async {
        let host = StubHostController()
        host.photosStatus = .authorized
        let model = makeModel(host: host, blockID: AlbumBlock.photo)
        model.setSource(.photosAsset(identifier: "asset-gone"))
        await model.awaitPendingLoad()
        XCTAssertEqual(model.loadState, .missingSource)
        model.prepareForRemoval()
    }

    func testEmptyAlbumIsReportedAsEmptyNotMissing() async {
        let host = StubHostController()
        host.photosStatus = .authorized
        fakeLibrary.albumTitles["album-empty"] = "空的"
        fakeLibrary.itemsByAlbum["album-empty"] = []

        let model = makeModel(host: host)
        model.setSource(.photosAlbum(identifier: "album-empty"))
        await model.awaitPendingLoad()
        XCTAssertEqual(model.loadState, .empty)
        model.prepareForRemoval()
    }

    // MARK: 权限引导通道

    func testPermissionGateIsSatisfiedByTheHostChannel() async {
        let host = StubHostController()
        host.photosStatus = .notDetermined
        let model = makeModel(host: host)
        model.setSource(.photosAlbum(identifier: "album-1"))
        await model.awaitPendingLoad()
        XCTAssertEqual(model.loadState, .photosPermission(.notDetermined))

        // 插件只经宿主的权限通道引导，自己不请求——这里模拟"用户在权限卡里授权后"
        // 宿主状态翻转，块重新枚举就该拿到数据。
        fakeLibrary.albumTitles["album-1"] = "最近项目"
        fakeLibrary.itemsByAlbum["album-1"] = [.photosAsset(identifier: "asset-1", capturedAt: nil)]
        host.photosStatus = .authorized
        await model.reloadAndWait()
        XCTAssertEqual(model.loadState, .ready(1))
        model.prepareForRemoval()
    }

    // MARK: 注册表

    func testRegistrySharesOneModelPerPlacementAndDiscardStopsItsTimer() async throws {
        let store = makeStore()
        let host = StubHostController()
        let folder = try makeFolder(named: "registry", files: ["a.jpg", "b.jpg"])

        let first = AlbumInstanceRegistry.shared.model(
            placementID: "placement-registry", blockID: AlbumBlock.carousel,
            stateStore: store, hostController: host)
        let second = AlbumInstanceRegistry.shared.model(
            placementID: "placement-registry", blockID: AlbumBlock.carousel,
            stateStore: store, hostController: host)
        XCTAssertTrue(first === second, "多屏视图副本必须观察同一个对象")

        first.setSource(.localFolder(path: folder.path))
        await first.awaitPendingLoad()
        first.setViewer(id: UUID(), visible: true)
        await first.awaitPendingLoad()
        XCTAssertTrue(first.isTimerRunning)

        AlbumInstanceRegistry.shared.discard(placementID: "placement-registry")
        XCTAssertFalse(first.isTimerRunning, "实例被移除后不得留下还在跑的计时")
        XCTAssertFalse(
            AlbumInstanceRegistry.shared.model(
                placementID: "placement-registry", blockID: AlbumBlock.carousel,
                stateStore: store, hostController: host) === first
        )
        AlbumInstanceRegistry.shared.discard(placementID: "placement-registry")
    }

    func testAttachServicesTouchesNothing() throws {
        // 装载期零 TCC、零文件系统：`attachServices` 只记住 store。
        let store = makeStore()
        let host = StubHostController()
        AlbumPlugin().attachServices(stateStore: store, hostController: host)
        XCTAssertEqual(fakeLibrary.albumQueryCount, 0)
        XCTAssertEqual(fakeLibrary.imageQueryCount, 0)
    }

    // MARK: 夹具

    private func makeStore() -> StateStore {
        StateStore(rootDirectory: root.appendingPathComponent("store-\(UUID().uuidString)"))
    }

    private func makeModel(
        host: StubHostController = StubHostController(),
        blockID: String = AlbumBlock.carousel
    ) -> AlbumPlacementModel {
        let model = AlbumPlacementModel(
            placementID: "placement-\(UUID().uuidString)",
            blockID: blockID,
            store: makeStore())
        model.attach(hostController: host)
        return model
    }

    /// 空文件即可：目录筛选只看扩展名，不看内容。
    private func makeFolder(named name: String, files: [String]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: folder.appendingPathComponent(file))
        }
        return folder
    }
}

// MARK: - 测试替身

/// 只为 `HostController` 存在的空宿主：补齐没有默认实现的五个成员，权限查询返回
/// 可配置的值（生产实现会读真实 TCC，测试里绝不走那条路）。
@MainActor
private final class StubHostController: HostController {
    var photosStatus: PermissionStatus = .authorized
    private(set) var presentedPermissions: [[SystemPermission]] = []

    func expandDrawer() {}
    func collapseDrawer() {}
    func enterEditMode() {}
    func exitEditMode() {}
    func refreshCompactDisplay() {}

    func permissionStatus(of permission: SystemPermission) -> PermissionStatus {
        permission == .photos ? photosStatus : .notDetermined
    }

    func presentPermissions(_ focus: [SystemPermission]) {
        presentedPermissions.append(focus)
    }
}

@MainActor
private final class FakePhotoLibrary: AlbumPhotoLibraryProtocol {
    var albumTitles: [String: String] = [:]
    var itemsByAlbum: [String: [AlbumItemRef]] = [:]
    var assetsByIdentifier: [String: AlbumItemRef] = [:]
    private(set) var albumQueryCount = 0
    private(set) var imageQueryCount = 0

    func albums() -> [AlbumAlbumRef] {
        albumQueryCount += 1
        return albumTitles.map {
            AlbumAlbumRef(id: $0.key, title: $0.value, assetCount: nil, isSmart: false)
        }
    }

    func albumTitle(forIdentifier identifier: String) -> String? {
        albumQueryCount += 1
        return albumTitles[identifier]
    }

    func items(inAlbum identifier: String, limit: Int) -> [AlbumItemRef] {
        albumQueryCount += 1
        return Array((itemsByAlbum[identifier] ?? []).prefix(limit))
    }

    func asset(identifier: String) -> AlbumItemRef? {
        albumQueryCount += 1
        return assetsByIdentifier[identifier]
    }

    func image(forAsset identifier: String, maxPixel: CGFloat) async -> CGImage? {
        imageQueryCount += 1
        return FakePhotoLibrary.pixel
    }

    /// 4×4 的纯色位图：够验证"取到了图"，又不值得为它写文件。
    private static let pixel: CGImage? = {
        guard
            let context = CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()
    }()
}

// MARK: - 测试用等待助手

extension AlbumPlacementModel {
    /// `reload()` 本身是同步入口（视图回调要能直接调），枚举在它派生的任务里跑；
    /// 测试需要把"已经重新枚举完"与断言的时刻对齐。
    func reloadAndWait() async {
        reload()
        await awaitPendingLoad()
    }
}
