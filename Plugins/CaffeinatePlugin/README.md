# Keep Awake（防休眠）

需要长时间挂机、下载或演示时，让 Mac 保持清醒。

## 提供的块

- **紧凑块 `caffeinate.toggle`**：点击直接切换“保持唤醒”开关，激活时图标点亮。

## 设置

设置视图提供同一个开关与状态说明。开启时会通过管理员授权调用 `pmset disablesleep` 抑制系统休眠；关闭后立即恢复正常的睡眠策略。

## 注意

- 首次开启会弹出系统管理员密码授权（`osascript with administrator privileges`）。
- 关闭应用或禁用插件会自动停止抑制。
