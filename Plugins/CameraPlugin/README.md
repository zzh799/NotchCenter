# Mirror（镜子）

开会前照一眼的摄像头镜像预览。

## 提供的块

### `camera.mirror`（镜子）

- 点击块内画面区域开始/停止预览。
- 预览走 `AVCaptureSession` + `AVCaptureVideoPreviewLayer`；会话由插件单例持有，多屏副本共享同一个会话（每份视图各自开关会互相打断）。
- 会话的启停放在后台线程（`startRunning()` 是阻塞调用）。
- 输入设备优先选内置广角摄像头，否则退回第一个可用设备。

## 权限

| 块 | 权限 |
|---|---|
| 镜子 | **摄像头**（`NSCameraUsageDescription`） |

摄像头权限被拒绝时，镜子块整块切换为引导态（说明用途 + 跳转权限管理），**不崩溃、不报错**，NotchCenter 其余功能不受影响。
