import Foundation

// MARK: - DDC/CI 帧编解码（纯逻辑，双后端共享）
//
// VESA DDC/CI 帧格式（布局对照 m1ddc sources/i2c.m 与 ddcctl src/DDC.c）：
// - Get VCP 请求：`[0x82, 0x01, vcp]`，首字节 0x82 = 0x80 | 载荷长度(2)。
// - Set VCP 请求：`[0x84, 0x03, vcp, hi, lo]`，0x84 = 0x80 | 载荷长度(4)。
// - 请求校验和 = 0x6E（显示器地址）^ 0x51（子地址）^ 消息逐字节异或。
// - Get VCP 回复（11 字节）：[0]=0x6E 源、[2]=0x02 命令、[4]=vcp、
//   [6..7]=量程上限（大端）、[8..9]=当前值（大端）、[10]=校验和
//   （0x6F ^ 0x51 ^ [1...9] 逐字节异或）。
//
// 运输层差异由两个后端各自处理：IOAVService 把 0x51 作为 I2C 子地址参数、
// 缓冲区不含前导 0x51；Intel IOI2C 把 0x51 放进发送缓冲区。

/// 本插件控制的 VCP 特征码（MCCS：亮度）。
enum VCPCode {
    static let luminance: UInt8 = 0x10
}

/// DDC/CI 消息编解码。
enum DDCPacketCodec {
    /// Get VCP 请求消息（不含校验和与运输层前导）。
    static func getMessage(vcp: UInt8) -> [UInt8] {
        [0x82, 0x01, vcp]
    }

    /// Set VCP 请求消息（不含校验和与运输层前导）。
    static func setMessage(vcp: UInt8, value: UInt16) -> [UInt8] {
        [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// 请求校验和：0x6E ^ 0x51 ^ 消息逐字节异或（m1ddc prepareDDCWrite 同款）。
    static func checksum(_ message: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0x6E ^ 0x51
        for byte in message { sum ^= byte }
        return sum
    }

    /// IOAVService 路线缓冲区：0x51 子地址走函数参数，缓冲区 = 消息 + 校验和。
    static func avServiceBuffer(_ message: [UInt8]) -> [UInt8] {
        message + [checksum(message)]
    }

    /// Intel IOI2C 路线缓冲区：0x51 前导进发送缓冲区（ddcctl 同款 7/5 字节帧）。
    static func i2cBuffer(_ message: [UInt8]) -> [UInt8] {
        [0x51] + message + [checksum(message)]
    }

    /// 解码 Get VCP 回复；源地址 / 命令 / 特征码 / 校验和任一不符即抛错。
    static func decodeReply(_ bytes: [UInt8], vcp: UInt8) throws -> LuminanceReading {
        guard bytes.count >= 11 else { throw BrightnessError.shortReply(count: bytes.count) }
        guard bytes[0] == 0x6E else { throw BrightnessError.badReplySource(bytes[0]) }
        guard bytes[2] == 0x02 else { throw BrightnessError.badReplyCommand(bytes[2]) }
        guard bytes[4] == vcp else { throw BrightnessError.badReplyVCP(bytes[4]) }
        var expected: UInt8 = 0x6F ^ 0x51
        for byte in bytes[1...9] { expected ^= byte }
        guard bytes[10] == expected else { throw BrightnessError.badReplyChecksum }
        let max = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        let current = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        return LuminanceReading(value: Int(current), max: Int(max))
    }
}
