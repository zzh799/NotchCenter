import AVFoundation

// MARK: - 摄像头设备枚举

/// 视频采集设备枚举（只用公开 API）。
///
/// 只服务 `camera.mirror`：配置预览会话时挑一个输入设备。刻意不暴露"是否被占用"——
/// 那属于隐私监控范畴，本插件不做。
enum CameraDevices {
    /// 当前系统里的视频采集设备。
    static func videoDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    /// 预览会话的首选输入设备：优先内置广角，否则退回第一个可用设备。
    static func preferredDevice() -> AVCaptureDevice? {
        let devices = videoDevices()
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }
}
