#import "WebIFCBridge.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach/mach.h>

// C++ 世界はこのファイルにのみ存在する
#include <string>
#include <vector>
#include <algorithm>
#include <glm/glm.hpp>
#include "web-ifc/parsing/IfcLoader.h"
#include "web-ifc/schema/IfcSchemaManager.h"
#include "web-ifc/geometry/IfcGeometryProcessor.h"

NSErrorDomain const IFCBridgeErrorDomain = @"jp.trapple.IFCQuickLook.Bridge";

@implementation IFCMeshChunk {
    NSData *_vertexData;
    NSData *_indexData;
    simd_float4 _color;
}
- (instancetype)initWithVertexData:(NSData *)v indexData:(NSData *)i color:(simd_float4)c {
    if ((self = [super init])) { _vertexData = v; _indexData = i; _color = c; }
    return self;
}
- (NSData *)vertexData { return _vertexData; }
- (NSData *)indexData { return _indexData; }
- (NSUInteger)vertexCount { return _vertexData.length / (6 * sizeof(float)); }
- (NSUInteger)indexCount { return _indexData.length / sizeof(uint32_t); }
- (simd_float4)color { return _color; }
@end

@interface IFCModelInfo ()
- (instancetype)initWithSchema:(NSString *)schema
                  elementCount:(NSUInteger)count
               omittedElements:(NSUInteger)omitted;
@end

@implementation IFCModelInfo {
    NSString *_schema;
    NSUInteger _count;
    NSUInteger _omitted;
}
- (instancetype)initWithSchema:(NSString *)s elementCount:(NSUInteger)c omittedElements:(NSUInteger)o {
    if ((self = [super init])) { _schema = s; _count = c; _omitted = o; }
    return self;
}
- (NSString *)schemaVersion { return _schema; }
- (NSUInteger)elementCount { return _count; }
- (NSUInteger)omittedElements { return _omitted; }
@end

/// プロセスの現在の物理フットプリント (MB)。取得失敗時は 0。
static double PhysFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (double)info.phys_footprint / 1024.0 / 1024.0;
}

/// ヘッダ部から FILE_SCHEMA を素朴に抽出（web-ifc に依存しない・先頭8KBのみ走査）
static NSString *SchemaFromHeader(const char *bytes, size_t len) {
    size_t n = std::min(len, (size_t)8192);
    std::string head(bytes, n);
    auto pos = head.find("FILE_SCHEMA");
    if (pos == std::string::npos) return nil;
    auto q1 = head.find('\'', pos);
    if (q1 == std::string::npos) return nil;
    auto q2 = head.find('\'', q1 + 1);
    if (q2 == std::string::npos) return nil;
    return [[NSString alloc] initWithBytes:head.data() + q1 + 1
                                    length:q2 - q1 - 1
                                  encoding:NSASCIIStringEncoding];
}

static NSError *MakeError(IFCBridgeError code, NSString *msg) {
    return [NSError errorWithDomain:IFCBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : msg}];
}

/// トークナイズ中のデッドライン超過を示す専用例外。
/// 日本語メッセージは Objective-C 側で NSError に載せる（C++ 例外の what() を
/// NSString の %s に通すと非ASCIIが失われるため、例外にはメッセージを持たせない）。
struct DeadlineExceeded {};

@implementation WebIFCBridge

- (nullable IFCModelInfo *)streamMeshesFromFileAtPath:(NSString *)path
                                          memoryCapMB:(NSUInteger)memoryCapMB
                                      deadlineSeconds:(double)deadlineSeconds
                                              handler:(void (NS_NOESCAPE ^)(IFCMeshChunk *))handler
                                                error:(NSError **)error {
    // --- mmap（コピーせず web-ifc に渡す） ---
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        if (error) *error = MakeError(IFCBridgeErrorCantOpen,
            [NSString stringWithFormat:@"ファイルを開けません: %@", path]);
        return nil;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size == 0) {
        close(fd);
        if (error) *error = MakeError(IFCBridgeErrorCantOpen, @"ファイルサイズを取得できません（空ファイル？）");
        return nil;
    }
    const size_t fileSize = (size_t)st.st_size;
    void *mapped = mmap(nullptr, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        if (error) *error = MakeError(IFCBridgeErrorCantOpen, @"mmap に失敗しました");
        return nil;
    }
    const char *bytes = (const char *)mapped;

    // --- スキーマ判定（Fail Fast: 非対応は読む前に弾く） ---
    NSString *schema = SchemaFromHeader(bytes, fileSize);
    if (schema == nil) {
        munmap(mapped, fileSize);
        if (error) *error = MakeError(IFCBridgeErrorParseFailed,
            @"IFC ヘッダ（FILE_SCHEMA）が見つかりません。IFC ファイルではない可能性があります");
        return nil;
    }
    NSString *upper = schema.uppercaseString;
    if (!([upper hasPrefix:@"IFC2X3"] || [upper hasPrefix:@"IFC4"])) { // IFC4 / IFC4X1..X3 を包含
        munmap(mapped, fileSize);
        if (error) *error = MakeError(IFCBridgeErrorUnsupportedSchema,
            [NSString stringWithFormat:@"非対応スキーマです: %@（対応: IFC2x3 / IFC4 / IFC4x3）", schema]);
        return nil;
    }

    NSUInteger elementCount = 0;
    NSUInteger omittedElements = 0;
    size_t totalTriangles = 0;
    try {
        webifc::schema::IfcSchemaManager schemas;
        const NSTimeInterval parseStart = [NSDate timeIntervalSinceReferenceDate];
        // 既定値は ModelManager.h の LoaderSettings に準拠（smoke テストで確定済み）
        webifc::parsing::IfcLoader loader(67108864, 268435456u, 10000, schemas); // memoryLimit=256MB: テープ超過分は再読込でページング（mmap元なので安価）
        // デッドラインはトークナイズにも適用する。ここが対象外だと巨大ファイルで
        // 数十秒無応答になり、直列化ゲートを握ったまま後続プレビューを道連れにする
        // （実地でハング報告あり）。ただしここはハング防止のバックストップなので
        // 2倍の猶予を取り、中型ファイルの「3秒で打ち切って部分表示」の道を潰さない。
        // ページング再読込（要素ループ中の再呼び出し）では投げない: そこは
        // 要素ループ側の毎要素判定で穏当に打ち切る。
        // 注: 例外時に web-ifc 内部の行カウント用バッファ（chunkSize分）が leak するが、
        // GB級ファイルを開いたときだけの稀な事象で有界なので許容する（vendor 側の実装都合）。
        bool tokenizing = true;
        loader.LoadFile([&](char *dest, size_t sourceOffset, size_t destSize) -> uint32_t {
            if (tokenizing && deadlineSeconds > 0 &&
                [NSDate timeIntervalSinceReferenceDate] - parseStart > deadlineSeconds * 2) {
                throw DeadlineExceeded{};
            }
            if (sourceOffset >= fileSize) return 0;
            size_t n = std::min(destSize, fileSize - sourceOffset);
            memcpy(dest, bytes + sourceOffset, n);
            return (uint32_t)n;
        });
        tokenizing = false;

        // circleSegments=12, coordinateToOrigin=true（巨大座標を原点に寄せ float 精度を守る）
        webifc::geometry::IfcGeometryProcessor processor(
            loader, schemas, 12, true,
            1.0E-04, 1.0E-04, 1.0E-04, 1.0E-10, 1.0E-04, 1, 150);

        std::vector<float> vbuf; // 再利用バッファ
        // 上限判定は「パース開始時点からの増分」で行う。
        // QL は appex プロセスを使い回すため、直前プレビューの残留メモリで
        // 開始時点から数百MB積まれていることがあり、絶対値判定だと即打ち切りになる。
        const double baselineMB = PhysFootprintMB();

        // 先に対象要素を列挙（メモリ上限打ち切り時に省略数を正確に数えるため）
        std::vector<uint32_t> targetIDs;
        for (auto type : schemas.GetIfcElementList()) {
            auto &ids = loader.GetExpressIDsWithType(type);
            targetIDs.insert(targetIDs.end(), ids.begin(), ids.end());
        }

        for (size_t idx = 0; idx < targetIDs.size(); idx++) {
                uint32_t eid = targetIDs[idx];
                // 時間デッドライン: ちら見用途では長くても数秒で見せる（速さ優先）。
                // 32要素ごとだと重い要素の連なりで大きく超過するため毎要素で判定する
                // （時刻取得のコストはジオメトリ処理に比べ無視できる）。
                // idx==0 は除外: 最低1要素は出して「ジオメトリなし」誤判定を防ぐ。
                if (idx != 0 && deadlineSeconds > 0 &&
                    [NSDate timeIntervalSinceReferenceDate] - parseStart > deadlineSeconds) {
                    omittedElements = targetIDs.size() - idx;
                    break;
                }
                // web-ifc は処理済みジオメトリを全てキャッシュし続け、大型モデルでは
                // ピークメモリがGB級になる（QL 拡張はメモリ上限があり圧縮スワップで激遅化）。
                // 要素は一巡しか処理しないため、定期的にキャッシュを解放する
                // （コストは共有ジオメトリの再計算のみ）。
                if (idx != 0 && idx % 32 == 0) {
                    processor.Clear();
                    // メモリ上限チェック: QL 拡張は footprint 約1GB から圧縮スワップで数倍遅くなるため、
                    // 余裕を持って手前で残りを省略して打ち切る（速さ優先・silent にしない）。
                    // 残留メモリ（前プレビュー分）が多い場合は baseline+250MB まで許容。
                    const double hardLimitMB = std::max(baselineMB + 250.0, (double)memoryCapMB);
                    if (memoryCapMB > 0 && PhysFootprintMB() > hardLimitMB) {
                        omittedElements = targetIDs.size() - idx;
                        break;
                    }
                }
                auto flat = processor.GetFlatMesh(eid);
                bool emitted = false;
                for (auto &pg : flat.geometries) {
                    auto &geom = processor.GetGeometry(pg.geometryExpressID);
                    // 注意: GetVertexDataSize() は GetVertexData() を呼ぶまで 0 を返す
                    // （double→float 変換が GetVertexData() 内で遅延実行されるため）
                    const float *vd = (const float *)geom.GetVertexData();
                    const size_t vCount = geom.GetVertexDataSize() / 6; // 6 float / 頂点
                    const size_t iCount = geom.GetIndexDataSize();
                    if (vd == nullptr || vCount == 0 || iCount == 0) continue;
                    const glm::dmat4 M = pg.transformation;
                    const glm::dmat3 N = glm::transpose(glm::inverse(glm::dmat3(M)));
                    vbuf.resize(vCount * 6);
                    for (size_t v = 0; v < vCount; v++) {
                        glm::dvec4 p = M * glm::dvec4(vd[v*6+0], vd[v*6+1], vd[v*6+2], 1.0);
                        glm::dvec3 nrm = glm::normalize(N * glm::dvec3(vd[v*6+3], vd[v*6+4], vd[v*6+5]));
                        vbuf[v*6+0] = (float)p.x; vbuf[v*6+1] = (float)p.y; vbuf[v*6+2] = (float)p.z;
                        vbuf[v*6+3] = (float)nrm.x; vbuf[v*6+4] = (float)nrm.y; vbuf[v*6+5] = (float)nrm.z;
                    }
                    NSData *vData = [NSData dataWithBytes:vbuf.data() length:vbuf.size() * sizeof(float)];
                    NSData *iData = [NSData dataWithBytes:(const void *)geom.GetIndexData()
                                                   length:iCount * sizeof(uint32_t)];
                    simd_float4 color = simd_make_float4((float)pg.color.r, (float)pg.color.g,
                                                         (float)pg.color.b, (float)pg.color.a);
                    handler([[IFCMeshChunk alloc] initWithVertexData:vData indexData:iData color:color]);
                    totalTriangles += iCount / 3;
                    emitted = true;
                }
                if (emitted) elementCount++;
        }
    } catch (const DeadlineExceeded &) {
        munmap(mapped, fileSize);
        if (error) *error = MakeError(IFCBridgeErrorDeadlineExceeded,
            @"時間内に読み込めませんでした（ファイルが大きすぎます）。IFCQuickLook.app で開いてください");
        return nil;
    } catch (const std::exception &e) {
        munmap(mapped, fileSize);
        // what() は UTF-8 として解釈する（stringWithFormat の %s は非ASCIIを落とす）
        NSString *what = [NSString stringWithUTF8String:e.what()] ?: @"";
        if (error) *error = MakeError(IFCBridgeErrorParseFailed,
            [NSString stringWithFormat:@"パースに失敗しました: %@", what]);
        return nil;
    } catch (...) {
        munmap(mapped, fileSize);
        if (error) *error = MakeError(IFCBridgeErrorParseFailed, @"パースに失敗しました（不明なC++例外）");
        return nil;
    }
    munmap(mapped, fileSize); // loader/processor はスコープを抜けて解放済み（トークンバッファ即解放）

    if (totalTriangles == 0) {
        if (error) *error = MakeError(IFCBridgeErrorNoGeometry, @"ジオメトリを持つ要素がありません");
        return nil;
    }
    return [[IFCModelInfo alloc] initWithSchema:upper elementCount:elementCount omittedElements:omittedElements];
}

@end
