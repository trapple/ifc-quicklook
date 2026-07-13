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
    IFCBridgeErrorDeadlineExceeded = 5,  // トークナイズがデッドラインを超過（巨大ファイル）
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
@property (nonatomic, readonly) NSUInteger omittedElements; // メモリ上限で打ち切った未処理要素数
@end

@interface WebIFCBridge : NSObject
/// ファイルを mmap で読み、要素単位でメッシュを handler にストリームする（呼び出しスレッドで同期実行）。
/// 成功時は IFCModelInfo、失敗時は nil + error（Fail Fast）。
/// memoryCapMB > 0 の場合、プロセスの phys_footprint がこの値を超えたら
/// 残り要素を省略して打ち切る（QL 拡張のメモリ上限での圧縮スワップ激遅化を防ぐ）。
/// deadlineSeconds > 0 の場合、経過時間がこれを超えても打ち切る（ちら見用途の速さ優先）。
/// 省略数は IFCModelInfo.omittedElements で通知される — silent にしない。
- (nullable IFCModelInfo *)streamMeshesFromFileAtPath:(NSString *)path
                                          memoryCapMB:(NSUInteger)memoryCapMB
                                      deadlineSeconds:(double)deadlineSeconds
                                              handler:(void (NS_NOESCAPE ^)(IFCMeshChunk *chunk))handler
                                                error:(NSError **)error
    NS_SWIFT_NAME(streamMeshes(fromFileAtPath:memoryCapMB:deadlineSeconds:handler:));
@end

NS_ASSUME_NONNULL_END
