import AppKit
import CryptoKit
import Foundation

// 剪贴板取证探针（决策记录 2026-09-20-clipboard-* 的配套诊断工具）
//
// 用途：把"一次复制到底往剪贴板写了几次、每次写了什么"变成可复现的输出。
//
// 为什么需要它：插件落盘历史里能看到"一次复制产生两条条目、相差 2 秒、第二条指向
// 输入法的缓存目录"，但那是**结果**不是成因。这个探针把每次 changeCount 跳变的时间、
// 类型清单、pasteboard item 结构与 fileURL 全打出来，用来区分——
//   ① 同一进程分两步写（两次跳变间隔毫秒级）；还是
//   ② 另一个进程（输入法 / 剪贴板同步工具）事后重写（间隔秒级）。
// 两者的修法完全不同：前者靠短时间去抖，后者只能靠内容等价去重。
//
// 用法（见 run.sh）：
//   ./run.sh watch [秒]             只观察，自己去别的 App 复制
//   ./run.sh copy <图片路径> [秒]    先把该图片写进剪贴板（fileURL + PNG 数据，模拟
//                                   CleanShot / Finder 的复制），再继续观察

func describe(_ pasteboard: NSPasteboard) {
    let items = pasteboard.pasteboardItems ?? []
    let types = pasteboard.types?.map(\.rawValue) ?? []
    print("  changeCount=\(pasteboard.changeCount) items=\(items.count)")
    print("  types=\(types)")
    for (index, item) in items.enumerated() {
        print("  item[\(index)] types=\(item.types.map(\.rawValue))")
        if let value = item.string(forType: .fileURL) {
            print("    fileURL = \(value)")
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = item.data(forType: type) {
                print("    \(type.rawValue) = \(data.count) bytes")
            }
        }
    }
    if let string = pasteboard.string(forType: .string) {
        print("    string = \(string.prefix(120))")
    }
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "watch"

switch mode {
case "copy":
    guard arguments.count > 2 else {
        print("用法：run.sh copy <图片路径> [观察秒数]")
        exit(2)
    }
    let fileURL = URL(fileURLWithPath: arguments[2])
    guard let data = try? Data(contentsOf: fileURL) else {
        print("读不到文件：\(fileURL.path)")
        exit(2)
    }
    let pasteboard = NSPasteboard.general
    // 与 CleanShot / Finder 的复制同构：一个 item 上既挂文件引用、又挂图像数据。
    let item = NSPasteboardItem()
    item.setString(fileURL.absoluteString, forType: .fileURL)
    item.setData(data, forType: .png)
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
    print("已写入剪贴板，来源 = \(fileURL.path)（\(data.count) bytes）")
    print("源文件 sha256 = \(sha256Hex(data))")

case "watch":
    break

case "compare":
    guard arguments.count > 3 else {
        print("用法：run.sh compare <图片A> <图片B>")
        exit(2)
    }
    for path in arguments[2...3] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let name = (path as NSString).lastPathComponent
        print("\(name)")
        print("  字节 sha256   = \(sha256Hex(data))  (\(data.count) bytes)")
        if let pixel = pixelFingerprint(data) {
            print("  像素 sha256   = \(pixel)")
        } else {
            print("  像素 sha256   = 解不出来")
        }
        if let size = imagePixelSize(data) {
            print("  像素尺寸      = \(Int(size.width))x\(Int(size.height))")
        }
    }
    exit(0)

default:
    print("未知模式：\(mode)（可用：watch / copy / compare）")
    exit(2)
}

let seconds: Double = {
    if let last = arguments.last, let value = Double(last) { return value }
    return 15
}()

let pasteboard = NSPasteboard.general
var lastCount = pasteboard.changeCount
var lastTime = Date()
print("\n起始状态：")
describe(pasteboard)

print("\n观察 \(Int(seconds)) 秒……\n")

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
    let count = pasteboard.changeCount
    guard count != lastCount else { continue }
    let now = Date()
    print("[+\(String(format: "%.3f", now.timeIntervalSince(lastTime)))s] changeCount \(lastCount) → \(count)")
    describe(pasteboard)
    print("")
    lastCount = count
    lastTime = now
}

print("观察结束。")

/// 与插件侧 `ClipboardMediaStore.contentHash` 同算法，便于直接比对两份字节是否一致。
func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 像素身份：按长边降到 512 再取 PNG 字节的哈希。
///
/// 这是插件 `contentHash` 的**候选实现**，用来回答"字节哈希能不能当身份"。同一张图被
/// 别的进程（输入法 / 剪贴板同步工具）重新压缩后落盘时，字节哈希必变、像素哈希应当不变。
/// 用"降采样后的字节"而不是原始像素缓冲：降采样本来就要为缩略图做一次，不额外付解码成本。
func pixelFingerprint(_ data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 512,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let encoded = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
    else { return nil }
    return sha256Hex(encoded)
}

func imagePixelSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: width, height: height)
}
