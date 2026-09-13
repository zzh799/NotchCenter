# Agent Note: 胶囊点击即时打断在飞滑动会话,消除弹簧飞行期点击死窗

status: implemented
date: 2026-09-13
deciders: zeaven

## Context(背景与约束)

用户报告:轻扫切页后立刻点分页胶囊毫无反应,需等约 0.5s 以上再点才生效。

根因是**滑动会话死窗**:`uiState.drawerSwipe` 从 `beginDrawerSwipe` 建房起,直到自驱弹簧收敛拍(`landDrawerSwipe`/`dissolveDrawerSwipe`)才清空——视觉收敛约 0.4–0.5s,按收敛判据(0.5pt/8pt/s)全程更长,上限 1.2s。这整段时间里 `DrawerPagePill.pressGesture.onEnded` 的 `guard !isSwipeActive` 把胶囊点击**静默丢弃**。

该互斥是旧机制时代的防御:彼时 `withAnimation(completion:)` 在 AppKit 事件上下文不保证触发,会话以 `isLanding` 卡死,胶囊点击若不丢弃会与卡死会话互锁(真机事故)。d531474 自驱弹簧重构消灭了卡死根因(会话必然收敛散场、"新输入随时接管"),但"会话期丢弃点击"这条守卫原样保留,退化成纯死窗。

**out of scope**:
- 4pt 点击意图门(`dragPickupDistance`)——按下位移超阈即不算点击,本次不动;
- 首访页面同步构建的卡顿(`rebuildContent` 走 `makeView` 全额首渲染)——与本次症状("毫无反应"而非"停顿后才开始动")不符;
- 驻留切页 `switchDrawerPageForDrag` 的 `noSwipe` 守卫——块拖拽与在飞会话正常不共存。

## Decision(决策)

**胶囊点击是新输入,即时打断在飞会话并跳到所点页**——与滑动通路"动画全程可接管(grab),无输入锁定期"([抽屉分页与滑动切页.md](../../agents/抽屉分页与滑动切页.md))同一哲学。

- 控制器(`NotchPanelContent`):`selectDrawerPage` 检测 `drawerSwipe != nil` 即走新私有路径 `interruptDrawerSwipe(selecting:)`——先 `swipeSpringDriver.cancel()` 停表(避免 `onFrame` 与重建互写)、`drawerScrollTracker.reset()`(同 `yieldDrawerSwipeToBlock` 先例)、`drawerActivePage = 所点页`、清会话、`rebuildContentAfterPageChange()`(spring)。**点原点页 = 取消飞行停在原页**;点目标页/任意其它页 = 取消飞行直接跳页。打断路径绕过 `canSwitchDrawerPage`:会话只在展开态存在,菜单跟踪/落点预览/块拖拽与在飞弹簧不共存。
- 视图(`DrawerPageCapsule`):`pressGesture.onEnded` 删除点击分支的 `guard !isSwipeActive`;**保留** `onChanged` 的同款守卫——编辑模式胶囊拖动排序仍不得在飞行期接管(与高光进度抢同一份水平位移)。

与红线"绝不允许在松手那一帧停贡献 + `selectDrawerPage`"的区别:那条管的是**手势释放通路**(停贡献、位移归零、换页挤进同一条 spring,真机"反向滑一遍"事故);本路径是**独立输入**(胶囊点击),页带层随会话清除而卸载、新页经常规 `rebuildContent` spring 交叉过渡,视觉语言与普通胶囊点击一致。打断瞬帧高光从飞行中位置 spring 到所点胶囊(`highlightKey` 跨越 -1 触发自身动画),无需额外处理。

## Alternatives considered(备选方案)

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 维持互斥,缩短会话存活(视觉收敛即散场) | 改动小 | 治标:窗口变短仍存在;改驱动器收敛语义会动落位精度与接管种子 | 否 |
| B. 会话期点击排队,收敛拍后补切 | 不打断动画 | 延迟感仍在;排队期间状态可能漂移(回弹/接管) | 否 |
| C. 点击即时打断并跳页(本方案) | 死窗归零;与 grab 哲学一致;复用常规重建路径 | 打断瞬帧的视觉需真机确认(理论同普通点击交叉过渡) | **采纳** |

## Consequences(影响)

- 领域文档 [抽屉分页与滑动切页.md](../../agents/抽屉分页与滑动切页.md) 的胶囊×滑动互斥条目同步改写(拖动排序仍互斥,点击不再互斥)。
- 控制器级路径(`selectDrawerPage`/会话)无单测缝隙(会话住在控制器状态,现有 `DrawerPageSwipeTests` 等均为纯判据单测),沿用仓库惯例以真机验证清单覆盖:①轻扫后立刻点另一颗胶囊 → 立即跳页;②飞行中点原点页 → 取消停在原页;③飞行中点第三页 → 干净跳页无"反向滑一遍"残影;④普通点击/编辑排序/驻留切页不回归。
- 后续若要做"首访页面预构建/悬停预热",与本决策正交,另行立项。

## Changelog

- v3.0.0:模板由 doc-driven-dev 3.0 提供(新增归档指引与模板自身 Changelog 段)。
