import Foundation

/// 整个效果就在这一个片元着色器里。
///
/// 上游 Mac-Duo 的 `DepthShaders`,原样移植。
///
/// 每个屏幕像素经逆透视映回画面坐标,再从高斯金字塔里按该处需要的模糊量挑一层
/// 采样。纹理里画面本来就压在黑底上,所以两者一起被模糊,画面边缘不需要特殊处理。
enum DepthShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // 全用 float4,布局就不会相对 Swift 侧漂移。
    struct Uniforms {
        float4 column0;          // 屏幕→画面的矩阵,列 0 放在 xyz
        float4 column1;
        float4 column2;
        float4 screenAndOrigin;  // 屏幕尺寸、画面点坐标下的 padding 原点
        float4 paddedAndBlur;    // padding 后尺寸、最大半径(像素)、模糊强度
        float4 shape;            // 模糊下限、最大变暗、像素比、最大层级
        float4 light;            // 变暗下限、变暗强度、变暗可达范围、保留
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    fragment float4 depthFragment(float4 position [[position]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<float> picture [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

        float2 screenSize = uniforms.screenAndOrigin.xy;
        float2 paddedOrigin = uniforms.screenAndOrigin.zw;
        float2 paddedSize = uniforms.paddedAndBlur.xy;
        float maxRadius = uniforms.paddedAndBlur.z;
        float strength = uniforms.paddedAndBlur.w;
        float blurFloor = uniforms.shape.x;
        float maxDim = uniforms.shape.y;
        float pixelScale = uniforms.shape.z;
        float maxLevel = uniforms.shape.w;
        float dimFloor = uniforms.light.x;
        float dimStrength = uniforms.light.y;
        float dimReach = uniforms.light.z;

        // 片元坐标是像素、y 向下;几何是点坐标、y 向上。
        float2 screenPoint = float2(position.x / pixelScale,
                                    screenSize.y - position.y / pixelScale);

        float3x3 screenToPicture = float3x3(uniforms.column0.xyz,
                                            uniforms.column1.xyz,
                                            uniforms.column2.xyz);
        float3 mapped = screenToPicture * float3(screenPoint, 1.0);
        if (abs(mapped.z) < 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 picturePoint = mapped.xy / mapped.z;

        float2 unit = (picturePoint - paddedOrigin) / paddedSize;
        if (unit.x < 0.0 || unit.x > 1.0 || unit.y < 0.0 || unit.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 texCoord = float2(unit.x, 1.0 - unit.y);

        float height = clamp(picturePoint.y / screenSize.y, 0.0, 1.0);
        float blur = strength * (blurFloor + (1.0 - blurFloor) * height);
        // 叫 level 会遮蔽 Metal 的 level() 选择子,故用 mipLevel。
        float mipLevel = clamp(log2(max(blur * maxRadius, 1.0)), 0.0, maxLevel);

        float4 colour = picture.sample(linearSampler, texCoord, level(mipLevel));
        // 用 smoothstep 而不是夹住的比值,这样变暗到达满强度的那个高度上
        // 不会留下可见的边。
        float spread = smoothstep(0.0, max(dimReach, 0.02), height);
        float fade = dimStrength * (dimFloor + (1.0 - dimFloor) * spread);
        // 采样是线性光。把系数取 2.2 次方,让变暗设置表现为编码亮度的一个比例。
        colour.rgb *= pow(1.0 - maxDim * fade, 2.2);
        return float4(colour.rgb, 1.0);
    }
    """
}
