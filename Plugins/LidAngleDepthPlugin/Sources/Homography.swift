import QuartzCore
import simd

/// 矩形到任意四边形的**投影映射**(单应矩阵)。
///
/// 上游 Mac-Duo 的 `Homography`,原样移植:合盖时玻璃在眼下转动,屏幕像素要按
/// 透视关系反查回画面里的坐标,这里给出那个变换。
public enum Homography {

    /// 把 (0, 0) 到 (`width`, `height`) 的矩形映射到 `corners`。
    ///
    /// `corners` 顺序:左下、右下、右上、左上。
    ///
    /// 列向量约定:`screen = matrix * (x, y, 1)`,再除以第三个分量。
    public static func matrix(width: Double, height: Double, to corners: [SIMD2<Double>]) -> simd_double3x3 {
        precondition(corners.count == 4, "four corners expected")
        let (x0, y0) = (corners[0].x, corners[0].y)
        let (x1, y1) = (corners[1].x, corners[1].y)
        let (x2, y2) = (corners[2].x, corners[2].y)
        let (x3, y3) = (corners[3].x, corners[3].y)

        // Heckbert 的单位正方形到四边形的解。
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g = 0.0
        var h = 0.0
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9 {
            let determinant = dx1 * dy2 - dx2 * dy1
            if abs(determinant) > 1e-12 {
                g = (dx3 * dy2 - dx2 * dy3) / determinant
                h = (dx1 * dy3 - dx3 * dy1) / determinant
            }
        }
        let a = x1 - x0 + g * x1
        let b = x3 - x0 + h * x3
        let c = x0
        let d = y1 - y0 + g * y1
        let e = y3 - y0 + h * y3
        let f = y0

        // 把 u = x / width、v = y / height 折进去。
        return simd_double3x3(columns: (
            SIMD3(a / width, d / width, g / width),
            SIMD3(b / height, e / height, h / height),
            SIMD3(c, f, 1)
        ))
    }

    /// 同一个映射,转置后给 Core Animation(它按行向量相乘)。
    public static func transform(width: CGFloat, height: CGFloat, to corners: [CGPoint]) -> CATransform3D {
        let m = matrix(
            width: Double(width),
            height: Double(height),
            to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
        )
        var t = CATransform3DIdentity
        t.m11 = CGFloat(m[0][0]); t.m12 = CGFloat(m[0][1]); t.m14 = CGFloat(m[0][2])
        t.m21 = CGFloat(m[1][0]); t.m22 = CGFloat(m[1][1]); t.m24 = CGFloat(m[1][2])
        t.m41 = CGFloat(m[2][0]); t.m42 = CGFloat(m[2][1]); t.m44 = CGFloat(m[2][2])
        return t
    }
}
