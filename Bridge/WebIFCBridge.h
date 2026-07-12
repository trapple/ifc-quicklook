// web-ifc への唯一の入り口。C++ はヘッダに露出させない（.mm に閉じ込める）。
#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const IFCBridgeErrorDomain;
typedef NS_ERROR_ENUM(IFCBridgeErrorDomain, IFCBridgeError) {
    IFCBridgeErrorCantOpen = 1,          // ファイルを開けない / mmap 失敗
    IFCBridgeErrorUnsupportedSchema = 2, // IFC2x3/IFC4/IFC4x3 以外
    IFCBridgeErrorParseFailed = 3,       // web-ifc がパースに失敗（C++例外含む）
    IFCBridgeErrorNoGeometry = 4,        // パースは通ったがジオメトリゼロ
};

/// 1要素・1配置分のメッシュ。頂点は position(xyz)+normal(xyz) の float32 6要素インターリーブ。
/// 配置変換は適用済み（原点寄せ済みの最終座標）。
@interface IFCMeshChunk : NSObject
- (instancetype)initWithVertexData:(NSData *)vertexData
                         indexData:(NSData *)indexData
                             color:(simd_float4)color;
@property (nonatomic, readonly) NSData *vertexData;   // float32 × 6 × vertexCount
@property (nonatomic, readonly) NSData *indexData;    // uint32 × indexCount
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSUInteger indexCount;
@property (nonatomic, readonly) simd_float4 color;    // RGBA 0-1
@end

@interface IFCModelInfo : NSObject
@property (nonatomic, readonly) NSString *schemaVersion;  // "IFC2X3" / "IFC4" / "IFC4X3" 等
@property (nonatomic, readonly) NSUInteger elementCount;  // ジオメトリを持つ要素数
@end

@interface WebIFCBridge : NSObject
/// ファイルを mmap で読み、要素単位でメッシュを handler にストリームする（呼び出しスレッドで同期実行）。
/// 成功時は IFCModelInfo、失敗時は nil + error（Fail Fast）。
- (nullable IFCModelInfo *)streamMeshesFromFileAtPath:(NSString *)path
                                              handler:(void (NS_NOESCAPE ^)(IFCMeshChunk *chunk))handler
                                                error:(NSError **)error
    NS_SWIFT_NAME(streamMeshes(fromFileAtPath:handler:));
@end

NS_ASSUME_NONNULL_END
