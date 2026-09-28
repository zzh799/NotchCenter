# Agent Note: 相册插件（文件夹轮播块 + 单张照片块）与 Photos 系统权限

status: implemented
date: 2026-09-28
deciders: 用户（拍板：交付 = 决策记录 + 完整实现；来源含 macOS 照片图库；轮播为自动播放 + 手动干预）
replaces: <无>
superseded-by: <无>

## Context(背景与约束)

需求是给抽屉加一个相册插件，含两个组件：**文件夹轮播**（自动播放、可手动干预）与**单张照片**。用户明确要求图片来源同时覆盖本地文件与 macOS 照片图库，并接受为此改动框架。

- **照片图库写入权限清单是框架级改动**：现有 `SystemPermission` 只有日历/提醒/摄像头/屏幕录制/辅助功能/定位六项，读图库需要一个新 case；这会改动公开枚举（`allCases` 与四个穷举 switch），对穷举 `switch SystemPermission` 的第三方插件是源码级破坏，因此按仓库惯例升 `NotchCenterKitAPI` 次版本并立 api-changelog。
- **抽屉是"短时可见 + 温存"的面板**：收起不卸载内容树（决策记录 2026-09-11-drawer-content-warmth），所以轮播定时器不能靠 `onDisappear` 收尾，必须读 `\.isDrawerPresented`。
- **同一份块视图在每块屏各有一份副本**，共享状态必须收敛为按 placementID 注册的唯一 `ObservableObject`，否则轮播会双倍推进。
- **权限四条红线**（docs/agents/系统集成与多语言.md）：插件不自行调 `requestAccess`、装载期零 TCC、缺权限只降级呈现、查询与请求分离。
- **只持有引用、不复制用户文件**：沿用 `ScratchpadStore` 契约。本插件只读；不复制、不移动、不删除用户原图，也不上传任何内容。
- 明确不做（out of scope）：视频与 Live Photo 播放、图库写入（新建相册/导入照片，故不需要 `NSPhotoLibraryAddUsageDescription`）、`PHPhotoLibraryChangeObserver` 实时刷新、人脸/地点等元数据浏览、图片编辑与滤镜。

## Decision(决策)

新增官方插件 `AlbumPlugin`（`PluginID = com.notchcenter.album`），提供两个抽屉块 `album.carousel` 与 `album.photo`；框架侧新增 `SystemPermission.photos`。

- **来源模型**：单一 `AlbumSource` 枚举（`localFolder` / `localImageFile` / `photosAlbum` / `photosAsset`），判别字段扁平 Codable（照 `RemindersSource` 手写编解码，磁盘数据不依赖合成实现）。轮播只接受集合型来源，单张只接受单体型来源，由 `accepts(_:forBlock:)` 约束。实现落点 `Plugins/AlbumPlugin/Sources/AlbumSource.swift`。
- **权限**：`SystemPermission` 新增 `case photos`（pane `Privacy_Photos`，用途键 `NSPhotoLibraryUsageDescription`，授权后无需重启），宿主 `PermissionCenter` 用 `PHPhotoLibrary.authorizationStatus(for: .readWrite)` 查询、`requestAuthorization(for: .readWrite)` 请求；`.limited` 映射为 `.authorized`（`PermissionStatus` 无受限态，且所选子集确实可读，不该判成不可用）。插件侧只经 `HostController.presentPermissions([.photos])` 引导，`attachServices` 不碰 PhotoKit。
- **播放归模型**：`AlbumCarouselInstanceModel` 持有洗牌/顺序序列与唯一可取消的 `Task` 循环；视图用稳定 `UUID` 登记"当前可见的副本"，模型在「至少一个可见副本 + 抽屉展开 + 项数 > 1 + 未暂停」时才跑表，收起即停（幂等），`layoutInfo.isPreview` 副本永不登记。
- **图片来源为引用**：本地存路径，图库存 `PHAsset.localIdentifier`；图库枚举与取图收敛在 `AlbumPhotoSource` 协议后的生产实现里（测试注入假实现），只把 `Sendable` 的值快照带出该层。
- **图片一律降采样后再进内存**：本地走 ImageIO `CGImageSourceCreateThumbnailAtIndex`，图库走 `PHImageManager.requestImage(targetSize:)`，目标像素 = 块边长 × 背板缩放；`NSCache` 键含目标像素尺寸，永不常驻原图；目录/相册枚举限 500 项并做失败负缓存。
- **刷新口径**：抽屉每次展开重新枚举（目录或相册资产），不接 `PHPhotoLibraryChangeObserver`（取舍见 Consequences）。
- 参考实现落点：块定义与状态机 `Plugins/AlbumPlugin/Sources/AlbumBlockViews.swift`，设置面板 `.../AlbumSettingsViews.swift`，实例模型与定时器 `.../AlbumInstance.swift`。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 一个插件两个块 + 新增 `SystemPermission.photos`（本决策） | 两个组件共用来源模型、解码缓存与权限引导；图库支持完整（相册轮播是核心诉求） | 需改 Kit 公开枚举，升次版本 | **采用** |
| B. 只做本地文件夹/文件，不碰图库 | 零框架改动、零权限 | 用户明确要求图库；"相册"名不副实 | 否决 |
| C. 拆成两个插件（本地相册 / 图库相册） | 各自独立演进 | 两份来源模型与解码缓存重复；用户要的是一个相册插件 | 否决 |
| D. 单张照片用 SwiftUI `PhotosPicker` 选图 | 系统原生 UX、全库可搜、选取本身免权限 | 选择器以 sheet 弹出，而**抽屉的鼠标停留区不含浮出窗口**（BlockPopover 的 `cardInset` 契约同源）：指针移向 sheet 的瞬间抽屉可能收起、设置浮卡被拆掉 | 否决（改为设置卡内自绘"相册列表 + 资产缩略网格"，交互不出卡片） |
| E. 接 `PHPhotoLibraryChangeObserver` 实时刷新 | 抽屉长开时新增照片立刻可见 | 引入跨屏失效广播与注册/注销生命周期；抽屉是短时面板，展开即重枚举已覆盖绝大多数场景 | 否决（记入 Consequences，若不满意再补） |
| F. 把选中的图库照片拷进插件数据目录 | 原图被删/移后仍能显示，且免持续权限 | 与"只持有引用"契约相悖；整库缩略图副本体积与隐私面都更大 | 否决 |
| G. 轮播定时器放视图 `@State` | 代码最短 | 多屏各一份视图副本 → 双倍推进；温存下收起不收尾 → 空转 | 否决 |

## Consequences(影响)

- **API**：`NotchCenterKitAPI.currentVersion` 1.5.0 → 1.6.0，新增 `docs/api-changelog/SystemPermission.md`。新增枚举 case 对穷举 switch 是源码级破坏（补 `@unknown default` 可免疫），对只做比较的插件零影响。
- **权限清单从 6 项变 7 项**：`PermissionGuidePanel` 的卡片高度原按"6 行 × 44pt"写死，需同步抬高，否则第 7 行被页脚裁掉。`PermissionTests` 的 pane 字典/rawValue 集合/重启名单必须同步，否则门禁红。
- **新增文件与隐私声明**：`NSPhotoLibraryUsageDescription` 进 `Resources/Info.plist`；用途文案需与枚举键 1:1（`PermissionTests` 守）。
- **不接变更观察者的代价**：抽屉长开期间新增/删除照片不会即时反映，收起再展开即刷新。若用户视为缺陷，补 `PHPhotoLibraryChangeObserver` 是一个局部增量（新增一个 hub，模型订阅其版本号），不需返工数据模型。
- **文档**：`docs/agents/系统集成与多语言.md` 的权限节需补 Photos 与本插件的降级态；`docs/产品路线图.md` 与选题调研的存量插件盘点表已滞后于现实（不止本次新增造成的），本决策不顺手改，避免范围外翻修。
- **系统文件面板必须非模态 + 抬层级**：用户实测报「文件选择窗被本程序 UI 挡住」——`NSOpenPanel` 默认层级 `NSModalPanelWindowLevel`（8）低于抽屉面板（`.statusBar` 25）与块浮窗（`.statusBar + 2` 27），且 `runModal()` 撞上面板与抽屉领域文档的模态循环红线。落点是 `AlbumLocalPicker`：非模态 `begin` + `.statusBar + 3` + 比视图长寿的持有者；通用纪律已沉淀进 `docs/agents/面板与抽屉.md`。
- **未验证项**：`Privacy_Photos` 锚点已在本机 `SecurityPrivacyExtension.appex` 的符号表中确认存在；`.limited` 是否真会在 macOS 上返回未见权威说明，按"映射为已授权"防御性处理，该分支若恒不触发也无害。

## Changelog

- v1:2026-09-28 首版：两块来源模型、播放归模型 + 可见副本登记、Photos 权限进框架、七条备选取舍。
