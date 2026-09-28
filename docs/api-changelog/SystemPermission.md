# API 变更日志:SystemPermission

> 每次对外变更在此**追加,新条目在上**;破坏性变更必须给迁移指引。
> 每个接口一份;内容沉淀后由对应 Agent Note 记录决策背景。

## 2026-09-28 · v1.6.0 · added
- 新增 `case photos`(照片图库读取,PhotoKit 消费方为相册插件 `AlbumPlugin`)。四档元数据:隐私面板锚点 `Privacy_Photos`、用途字符串键 `NSPhotoLibraryUsageDescription`、引导图标 `photo.on.rectangle`、`requiresRelaunch == false`(PhotoKit 授权当次进程即时生效)。
- 宿主侧同步接入:查询走 `PHPhotoLibrary.authorizationStatus(for: .readWrite)`,请求走 `requestAuthorization(for: .readWrite)`;`.limited`(用户只授权部分照片)**并入 `.authorized`**——Kit 四态无受限档,且受限选集确实可读,判成不可用会把可用功能锁死。`.readWrite` 是 PhotoKit 唯一的读档位(没有纯读级别)。
- 兼容性:破坏(仅对**穷举 `switch SystemPermission`** 的插件——补 `@unknown default` 即可免疫;`allCases` 增项也会让按清单渲染的 UI 多出一行)。只做 `==` 比较、或直接使用 `SystemPermission.allCases` 渲染的插件零代码改动。
- 迁移:若你的插件穷举了 `SystemPermission`,补一个 `@unknown default` 分支;若按清单渲染权限 UI,新增行会自动出现,但**宿主侧**的 `permission.name.photos` / `permission.purpose.photos` 文案由宿主提供,插件无须自备。
- 关联 Agent Note:[2026-09-28-album-plugin](../agent-notes/implemented/2026-09-28-album-plugin.md)

## Changelog
- v1.6.0:新增 `case photos`(2026-09-28)。
