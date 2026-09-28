import Foundation
import Testing
@testable import AlbumPlugin

// MARK: - 来源模型（纯逻辑；不碰磁盘、不碰 PhotoKit）

@Suite("相册 · 来源模型")
struct AlbumSourceTests {
    private static let allSources: [AlbumSource] = [
        .localFolder(path: "/tmp/folder"),
        .localImageFile(path: "/tmp/one.jpg"),
        .photosAlbum(identifier: "album-1"),
        .photosAsset(identifier: "asset-1"),
    ]

    @Test func sourceRoundTripsThroughFlatDiskShape() throws {
        for source in Self.allSources {
            let data = try JSONEncoder().encode(source)
            #expect(try JSONDecoder().decode(AlbumSource.self, from: data) == source)
            // 磁盘形状必须是"判别字段 + 值"的扁平结构：合成 Codable 对关联值 enum
            // 生成的形状随 Swift 版本浮动，而这份数据要长期躺在用户磁盘上。
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(object.count == 2)
            #expect(object["type"] != nil)
            #expect(object["value"] != nil)
        }
    }

    @Test func unknownTypeFailsToDecode() {
        let json = Data(#"{"type":"futureSource","value":"x"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AlbumSource.self, from: json)
        }
    }

    @Test func shapeAndOriginAreReportedPerCase() {
        #expect(AlbumSource.localFolder(path: "/a").isCollection)
        #expect(AlbumSource.photosAlbum(identifier: "a").isCollection)
        #expect(!AlbumSource.localImageFile(path: "/a").isCollection)
        #expect(!AlbumSource.photosAsset(identifier: "a").isCollection)

        #expect(!AlbumSource.localFolder(path: "/a").isFromPhotosLibrary)
        #expect(!AlbumSource.localImageFile(path: "/a").isFromPhotosLibrary)
        #expect(AlbumSource.photosAlbum(identifier: "a").isFromPhotosLibrary)
        #expect(AlbumSource.photosAsset(identifier: "a").isFromPhotosLibrary)
    }

    @Test func blockAcceptsOnlyMatchingShape() {
        // 轮播只收集合型，单张只收单体型——形状不匹配的一律拒收，否则块会永远空着。
        #expect(
            AlbumSource.accepts(.localFolder(path: "/a"), forBlock: AlbumBlock.carousel))
        #expect(
            AlbumSource.accepts(.photosAlbum(identifier: "a"), forBlock: AlbumBlock.carousel))
        #expect(
            !AlbumSource.accepts(.localImageFile(path: "/a"), forBlock: AlbumBlock.carousel))
        #expect(
            !AlbumSource.accepts(.photosAsset(identifier: "a"), forBlock: AlbumBlock.carousel))

        #expect(AlbumSource.accepts(.localImageFile(path: "/a"), forBlock: AlbumBlock.photo))
        #expect(AlbumSource.accepts(.photosAsset(identifier: "a"), forBlock: AlbumBlock.photo))
        #expect(!AlbumSource.accepts(.localFolder(path: "/a"), forBlock: AlbumBlock.photo))
        #expect(!AlbumSource.accepts(.photosAlbum(identifier: "a"), forBlock: AlbumBlock.photo))

        #expect(!AlbumSource.accepts(.localFolder(path: "/a"), forBlock: "unknown.block"))
    }

    @Test func localPathsAreAbbreviatedAndPhotosIdentifiersAreSeparate() {
        let home = NSHomeDirectory()
        let source = AlbumSource.localFolder(path: home + "/Pictures/相册")
        #expect(source.localPath == "~/Pictures/相册")
        #expect(source.photosIdentifier == nil)
        #expect(AlbumSource.photosAlbum(identifier: "album-1").localPath == nil)
        #expect(AlbumSource.photosAsset(identifier: "asset-1").photosIdentifier == "asset-1")
    }
}

// MARK: - 配置容错

@Suite("相册 · 配置容错")
struct AlbumConfigTests {
    @Test func missingFieldsFallBackToDefaults() throws {
        let config = try JSONDecoder().decode(CarouselConfig.self, from: Data("{}".utf8))
        #expect(config.source == nil)
        #expect(config.intervalSeconds == AlbumIntervals.fallback)
        #expect(!config.randomOrder)
        #expect(!config.recursive)
        #expect(config.fillsFrame)
        #expect(config.showsCaption)
    }

    @Test func unknownSourceTypeDegradesToUnconfigured() throws {
        let json = Data(
            #"{"version":1,"source":{"type":"futureSource","value":"x"},"intervalSeconds":5}"#.utf8)
        let config = try JSONDecoder().decode(CarouselConfig.self, from: json)
        // 来源读不出来就按"没配"处理，而不是整份配置失效——用户重选一次即可。
        #expect(config.source == nil)
        #expect(config.intervalSeconds == 5)
    }

    @Test func photoConfigDecodesWithDefaults() throws {
        let config = try JSONDecoder().decode(PhotoConfig.self, from: Data("{}".utf8))
        #expect(config.source == nil)
        #expect(config.fillsFrame)
        #expect(config.showsCaption)
    }

    @Test func intervalSnapsToNearestAllowedStep() {
        #expect(AlbumConfigLogic.sanitizeInterval(0) == 3)
        #expect(AlbumConfigLogic.sanitizeInterval(4.4) == 5)
        #expect(AlbumConfigLogic.sanitizeInterval(9) == 8)
        #expect(AlbumConfigLogic.sanitizeInterval(1_000) == 60)
        #expect(AlbumConfigLogic.sanitizeInterval(-5) == 3)
        #expect(AlbumConfigLogic.sanitizeInterval(.nan) == AlbumIntervals.fallback)
        #expect(AlbumConfigLogic.sanitizeInterval(.infinity) == AlbumIntervals.fallback)
    }

    @Test func sanitizeDropsSourcesWhoseShapeDoesNotFitTheBlock() {
        #expect(
            AlbumConfigLogic.sanitize(
                source: .localFolder(path: "/a"), forBlock: AlbumBlock.photo) == nil)
        #expect(
            AlbumConfigLogic.sanitize(
                source: .localImageFile(path: "/a"), forBlock: AlbumBlock.photo)
                == .localImageFile(path: "/a"))
        #expect(AlbumConfigLogic.sanitize(source: nil, forBlock: AlbumBlock.carousel) == nil)
    }
}

// MARK: - 播放次序

/// 确定性随机源：洗牌要在单测里可复现。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("相册 · 播放次序")
struct AlbumOrderTests {
    @Test func sequentialAdvancesWrapAround() {
        #expect(AlbumOrder.nextSequential(after: 0, count: 3) == 1)
        #expect(AlbumOrder.nextSequential(after: 2, count: 3) == 0)
    }

    @Test func previousWrapsBackwards() {
        #expect(AlbumOrder.previousSequential(before: 2, count: 3) == 1)
        #expect(AlbumOrder.previousSequential(before: 0, count: 3) == 2)
    }

    @Test func emptyAndSingleItemCollectionsNeverMove() {
        #expect(AlbumOrder.nextSequential(after: 0, count: 0) == 0)
        #expect(AlbumOrder.nextSequential(after: 5, count: 1) == 0)
        #expect(AlbumOrder.previousSequential(before: 5, count: 1) == 0)
        var generator = AnyGenerator()
        #expect(AlbumOrder.shuffledQueue(count: 0, previous: nil, using: &generator).isEmpty)
    }

    @Test func shuffleIsAPermutationThatNeverRepeatsThePreviousImage() {
        var generator = SeededGenerator(seed: 42)
        var previous: Int? = 7
        // 跨轮交界处连播同一张 = 观感上卡住了，这条是随机模式最容易出的 bug。
        for _ in 0..<200 {
            let order = AlbumOrder.shuffledQueue(count: 8, previous: previous, using: &generator)
            #expect(order.count == 8)
            #expect(Set(order) == Set(0..<8))
            #expect(order.first != previous)
            previous = order.last
        }
    }

    @Test func shuffleOfTwoItemsStillAvoidsImmediateRepeat() {
        var generator = SeededGenerator(seed: 3)
        var previous: Int? = 1
        for _ in 0..<50 {
            let order = AlbumOrder.shuffledQueue(count: 2, previous: previous, using: &generator)
            #expect(order.first != previous)
            previous = order.last
        }
    }

    @Test func cursorCoversEveryIndexExactlyOncePerRound() {
        var generator = SeededGenerator(seed: 7)
        var cursor = AlbumShuffleCursor()
        var seen: [Int] = []
        var current: Int?
        for _ in 0..<6 {
            current = cursor.next(count: 6, current: current, using: &generator)
            seen.append(current ?? -1)
        }
        #expect(Set(seen).count == 6, "一轮里每张只应出现一次")
        #expect(cursor.pendingCount == 0)
    }

    @Test func cursorReshufflesWhenTheItemCountChanges() {
        var generator = SeededGenerator(seed: 11)
        var cursor = AlbumShuffleCursor()
        _ = cursor.next(count: 4, current: nil, using: &generator)
        // 来源换了（张数变了）：旧队列必须整轮作废，否则会拿到越界下标。
        let value = cursor.next(count: 2, current: 1, using: &generator)
        #expect((0..<2).contains(value))
    }
}

/// `shuffledQueue(count: 0)` 也要求一个生成器，给它一个最简实现。
private struct AnyGenerator: RandomNumberGenerator {
    mutating func next() -> UInt64 { 0 }
}

// MARK: - 缓存键

@Suite("相册 · 取图缓存键")
struct AlbumImageKeyTests {
    @Test func bucketRoundsUpToTheNextStop() {
        #expect(AlbumImageKey.bucket(forPixel: 1) == 256)
        #expect(AlbumImageKey.bucket(forPixel: 256) == 256)
        #expect(AlbumImageKey.bucket(forPixel: 257) == 512)
        #expect(AlbumImageKey.bucket(forPixel: 1_200) == 2048)
        #expect(AlbumImageKey.bucket(forPixel: 3_000) == 4096)
        #expect(AlbumImageKey.bucket(forPixel: 99_999) == 4096)
    }

    @Test func nonPositiveAndNonFinitePixelsFallBackToTheSmallestBucket() {
        // 尺寸还没上报（0）时不能算出越界的档位；NaN/无穷也要挡住。
        #expect(AlbumImageKey.bucket(forPixel: 0) == 256)
        #expect(AlbumImageKey.bucket(forPixel: -10) == 256)
        #expect(AlbumImageKey.bucket(forPixel: .nan) == 256)
        #expect(AlbumImageKey.bucket(forPixel: .infinity) == 256)
    }

    @Test func keySeparatesKindAndBucket() {
        let file = AlbumItemRef.localFile(path: "/tmp/a.jpg", title: "a.jpg")
        let asset = AlbumItemRef.photosAsset(identifier: "/tmp/a.jpg", capturedAt: nil)
        #expect(AlbumImageKey.key(for: file, bucket: 512) != AlbumImageKey.key(for: asset, bucket: 512))
        #expect(AlbumImageKey.key(for: file, bucket: 512) != AlbumImageKey.key(for: file, bucket: 1024))
        #expect(AlbumImageKey.key(for: file, bucket: 512) == AlbumImageKey.key(for: file, bucket: 512))
    }
}

// MARK: - 目录筛选（纯函数部分）

@Suite("相册 · 目录筛选")
struct AlbumFolderSelectTests {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/album-fixture/\($0)") }
    }

    @Test func keepsOnlyImageFiles() {
        let selected = AlbumFolderScan.selectImages(
            from: urls(["a.jpg", "notes.txt", "b.PNG", "clip.mov", "c.heic", "d.webp", "e"]))
        #expect(selected.map(\.identifier) == [
            "/tmp/album-fixture/a.jpg",
            "/tmp/album-fixture/b.PNG",
            "/tmp/album-fixture/c.heic",
            "/tmp/album-fixture/d.webp",
        ])
    }

    @Test func sortsLikeFinder() {
        // 数字按数值大小排（"2" 在 "10" 前），不是字典序。
        let selected = AlbumFolderScan.selectImages(from: urls(["10.jpg", "2.jpg", "1.jpg"]))
        #expect(selected.map(\.title) == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test func capsAtTheLimit() {
        let names = (1...600).map { "\($0).jpg" }
        #expect(AlbumFolderScan.selectImages(from: urls(names)).count == AlbumFolderScan.maxFiles)
        #expect(AlbumFolderScan.selectImages(from: urls(names), limit: 3).count == 3)
        #expect(AlbumFolderScan.selectImages(from: urls(names), limit: 0).isEmpty)
    }

    @Test func titlesCarryTheFileName() {
        let selected = AlbumFolderScan.selectImages(from: urls(["holiday.jpg"]))
        #expect(selected.first?.title == "holiday.jpg")
        #expect(selected.first?.kind == .localFile)
    }
}
