# IFC Quick Look 実装プラン

> **実装者向け:** このプランは subagent-driven-development (推奨) または手動実行で消化する。step は `- [ ]` チェックボックスで track する。
> 本 PJ では **branch + 直列（このセッションで順に実装）** が決定済み。

**Goal:** macOS の Quick Look（スペースキー）で `.ifc` ファイルを 3D インタラクティブ表示する Quick Look プレビュー拡張を作る。

**Architecture:** web-ifc（C++）をネイティブ静的ライブラリとしてビルドし、Obj-C++ シム（WebIFCBridge）でメッシュストリームとして Swift に公開。色別に MeshResource へ統合し RealityKit の ARView（AppKit・非AR）で描画。ホストアプリ・QL appex・CLI ベンチ・テストの 4 ターゲットがソース共有（フレームワークなし）で同じコアを使う。

**Tech Stack:** Swift (言語モード5) / Obj-C++ / web-ifc (ThatOpen engine_web-ifc, MPL-2.0, submodule) / RealityKit (ARView + MeshDescriptor) / XcodeGen / CMake / XCTest

## Global Constraints

### Spec 由来 (spec から逐語コピー)

- 最重要制約: **軽さ = 表示速度（体感）とメモリ・CPU負荷**。アプリサイズ・実装コストは劣後
- スコープ: **プレビュー拡張のみ**（スペースキー）。サムネイル拡張は作らない
- 対象規模: **数百MB級の IFC も真面目に対応**。目標: 初回描画1秒以内（プログレッシブ）、フル表示は数秒〜十数秒
- 対応スキーマ: IFC2x3 / IFC4 / IFC4x3（web-ifc の対応範囲）
- 対応macOS: 15+
- **三角形数上限 2000万**。超過分はスキップし「⚠︎ N要素を省略」と表示（silent にしない）
- パース失敗 / 非対応スキーマ / ジオメトリゼロ → エラービューで**理由を明示**。空画面・汎用アイコンに逃げない
- C++ 例外はシム層で全捕捉 → Swift の Result に変換
- `.ifc` は **mmap**（コピーせず web-ifc に渡す）
- パース完了後、web-ifc 側のトークンバッファを即解放。保持は **MeshResource（GPU側）+ 色テーブルのみ**（中間の CPU 頂点配列は統合後に破棄）
- 頂点レイアウト: position(float3) + normal(float3)、インデックス 32bit
- カメラ: ドラッグ = オービット / スクロール・ピンチ = ズーム / 右ドラッグ or Shift+ドラッグ = パン。初期視点: モデル bbox 中心を注視点に斜め上 45° の等角風
- 配布: まず自分用（開発署名）。App Store 対象外。notarize は将来 OSS 公開時（本プランのスコープ外）

### PJ 恒久ルール (CLAUDE.md / `.claude/rules/` 由来)

- コメント・説明は日本語で記述する
- `cd <dir> && git ...` ではなく `git -C <dir> ...` を使う
- 外部プロセス起動（ビルド・curl 等）にはハングを想定し timeout を意識する
- 小さくイテレーションを回す: 数KB の fixture で動作確認してから大きいファイルに進む
- main 直コミット禁止（本 PJ は `feature/ifc-quicklook-design` branch 上で作業）

### 運用前提 (brainstorming で確定した実装方式)

- 実装スタイル **B: branch + 直列**。branch `feature/ifc-quicklook-design` は作成済み・spec コミット済み
- 実装は **Fable 5 モデル**で行う（subagent を使う場合も fable 指定）
- 開発機: macOS 26 / Xcode 26 想定。署名はローカル ad-hoc（`CODE_SIGN_IDENTITY=-`）で開始し、配布時に Developer ID へ切替（スコープ外）

---

## ファイル構造

```
ifc-quicklook/
├── .gitignore
├── README.md
├── project.yml                      # XcodeGen 定義（xcodeproj は生成物、git 管理外）
├── vendor/web-ifc/                  # git submodule（タグ固定）
├── scripts/build-webifc.sh          # web-ifc → .webifc/{lib,include} に静的ライブラリ集約
├── .webifc/                         # ビルド生成物（git 管理外）
├── Bridge/
│   ├── IFCQuickLook-Bridging-Header.h
│   ├── WebIFCBridge.h               # 純 Obj-C ヘッダ（C++ 非露出）
│   ├── WebIFCBridge.mm              # web-ifc 呼び出し（C++ はこの 1 ファイルに閉じ込め）
│   └── smoke/test_load.cpp          # M1: API 疎通確認用（Xcode 不使用の素の clang++）
├── Shared/
│   ├── MeshBatcher.swift            # 色別統合・三角形上限・AABB
│   ├── ModelLoader.swift            # mmap→パース→バッチの AsyncThrowingStream
│   ├── RKSceneBuilder.swift         # MaterialBatch → ModelEntity
│   ├── OrbitCameraController.swift  # 球面座標カメラ
│   ├── ViewerARView.swift           # ARView サブクラス（マウス/スクロール/ピンチ）
│   └── ViewerViewController.swift   # ARView + オーバーレイ + エラービュー（App と appex で共用）
├── App/
│   ├── Main.swift                   # プログラマティック NSApp・Open メニュー
│   ├── App-Info.plist               # UTI 宣言（org.buildingsmart.ifc）
│   └── App.entitlements
├── PreviewExtension/
│   ├── PreviewViewController.swift  # QLPreviewingController
│   ├── PreviewExtension-Info.plist
│   └── PreviewExtension.entitlements
├── Bench/
│   └── main.swift                   # ifcql-bench（時間・三角形数・ピークメモリ）
└── Tests/
    ├── Fixtures/minimal_wall.ifc    # 手書き最小 IFC4（壁1枚 = 直方体）
    ├── Fixtures/broken.ifc
    ├── Fixtures/unsupported_schema.ifc
    ├── WebIFCBridgeTests.swift
    └── MeshBatcherTests.swift
```

**Interfaces 全体図**（型はタスク間で厳密に一致させること）:

- `WebIFCBridge` (ObjC): `- (nullable IFCModelInfo *)streamMeshesFromFileAtPath:(NSString *)path handler:(void (^)(IFCMeshChunk *))handler error:(NSError **)error;`
  → Swift からは `func streamMeshes(fromFileAtPath: String, handler: (IFCMeshChunk) -> Void) throws -> IFCModelInfo`
- `IFCMeshChunk` (ObjC): `vertexData: NSData`(float32 ×6/頂点, 変換適用済), `indexData: NSData`(uint32), `vertexCount/indexCount: NSUInteger`, `color: simd_float4`
- `IFCModelInfo` (ObjC): `schemaVersion: NSString`, `elementCount: NSUInteger`
- `AABB` (Swift struct): `min/max: SIMD3<Float>`
- `MaterialBatch` (Swift struct): `color: SIMD4<Float>`, `vertices: [Float]`, `indices: [UInt32]`
- `MeshBatcher` (Swift class): `init(triangleLimit: Int)`, `add(_: IFCMeshChunk) -> Bool`, `drain() -> [MaterialBatch]`, `totalTriangles/skippedElements: Int`, `bounds: AABB?`
- `LoadSummary` (Swift struct): `schema: String`, `elementCount: Int`, `triangleCount: Int`, `skippedElements: Int`, `seconds: Double`, `bounds: AABB?`
- `LoadEvent` (Swift enum): `.batches([MaterialBatch])` / `.finished(LoadSummary)`
- `ModelLoader` (Swift class): `func events(for url: URL, triangleLimit: Int, flushInterval: Double) -> AsyncThrowingStream<LoadEvent, Error>`
- `RKSceneBuilder` (Swift enum): `static func makeEntities(_ batches: [MaterialBatch]) -> [ModelEntity]`
- `OrbitCameraController` (Swift class): `orbit(dx:dy:)`, `zoom(delta:)`, `pan(dx:dy:)`, `frame(_ bbox: AABB)`, `apply(to entity: Entity)`
- `ViewerViewController` (Swift): `func start(url: URL)`, `func show(message: String)`

---

### Task 1: リポジトリ基盤 + 最小 IFC fixture

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `Tests/Fixtures/minimal_wall.ifc`

**Interfaces:**
- Produces: `Tests/Fixtures/minimal_wall.ifc` — 以降全タスクの検証入力。壁1枚（4m × 0.3m × 3m の直方体、12三角形）

- [ ] **Step 1: .gitignore と README を作成**

`.gitignore`:

```gitignore
# ビルド生成物
build/
.webifc/
DerivedData/
# XcodeGen 生成物（project.yml が正）
*.xcodeproj
xcuserdata/
.DS_Store
```

`README.md`:

```markdown
# IFC Quick Look

macOS の Quick Look（スペースキー）で `.ifc`（BIM）ファイルを 3D 表示するプレビュー拡張。

- エンジン: [web-ifc](https://github.com/ThatOpen/engine_web-ifc)（ネイティブビルド）
- 描画: RealityKit（ARView / AppKit）
- 対応: IFC2x3 / IFC4 / IFC4x3, macOS 15+

## ビルド

```sh
brew install cmake xcodegen
git submodule update --init --recursive
./scripts/build-webifc.sh
xcodegen generate
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook build
```

設計: `.claude/specs/2026-07-12-ifc-quicklook-design.md`
```

- [ ] **Step 2: 最小 IFC fixture を手書きで作成**

`Tests/Fixtures/minimal_wall.ifc`（IFC4・壁1枚。IfcExtrudedAreaSolid で 4×0.3 の矩形を高さ 3 に押し出し）:

```
ISO-10303-21;
HEADER;
FILE_DESCRIPTION((''),'2;1');
FILE_NAME('minimal_wall.ifc','2026-07-12T00:00:00',(''),(''),'','','');
FILE_SCHEMA(('IFC4'));
ENDSEC;
DATA;
#1=IFCPROJECT('0YvctVUKr0kugbFTf53O9L',$,'Project',$,$,$,$,(#20),#7);
#7=IFCUNITASSIGNMENT((#8));
#8=IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.);
#20=IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,1.E-05,#21,$);
#21=IFCAXIS2PLACEMENT3D(#22,$,$);
#22=IFCCARTESIANPOINT((0.,0.,0.));
#30=IFCSITE('0YvctVUKr0kugbFTf53O9M',$,'Site',$,$,#31,$,$,.ELEMENT.,$,$,$,$,$);
#31=IFCLOCALPLACEMENT($,#21);
#40=IFCBUILDING('0YvctVUKr0kugbFTf53O9N',$,'Building',$,$,#41,$,$,.ELEMENT.,$,$,$);
#41=IFCLOCALPLACEMENT(#31,#21);
#45=IFCBUILDINGSTOREY('0YvctVUKr0kugbFTf53O9O',$,'Storey',$,$,#46,$,$,.ELEMENT.,0.);
#46=IFCLOCALPLACEMENT(#41,#21);
#50=IFCWALL('0YvctVUKr0kugbFTf53O9P',$,'Wall',$,$,#51,#60,$,$);
#51=IFCLOCALPLACEMENT(#46,#21);
#60=IFCPRODUCTDEFINITIONSHAPE($,$,(#61));
#61=IFCSHAPEREPRESENTATION(#20,'Body','SweptSolid',(#62));
#62=IFCEXTRUDEDAREASOLID(#63,#21,#66,3.);
#63=IFCRECTANGLEPROFILEDEF(.AREA.,$,#64,4.,0.3);
#64=IFCAXIS2PLACEMENT2D(#65,$);
#65=IFCCARTESIANPOINT((0.,0.));
#66=IFCDIRECTION((0.,0.,1.));
#70=IFCRELAGGREGATES('0YvctVUKr0kugbFTf53O9Q',$,$,$,#1,(#30));
#71=IFCRELAGGREGATES('0YvctVUKr0kugbFTf53O9R',$,$,$,#30,(#40));
#72=IFCRELAGGREGATES('0YvctVUKr0kugbFTf53O9S',$,$,$,#40,(#45));
#73=IFCRELCONTAINEDINSPATIALSTRUCTURE('0YvctVUKr0kugbFTf53O9T',$,$,$,(#50),#45);
ENDSEC;
END-ISO-10303-21;
```

※ この fixture の正当性は Task 3 の smoke テストで検証される（`triangles=12` が期待値）。web-ifc がパースエラーを返す場合はエラーメッセージの行番号を見て fixture 側を修正する。

- [ ] **Step 3: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add .gitignore README.md Tests/Fixtures/minimal_wall.ifc
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "chore: リポジトリ基盤と最小IFC fixtureを追加"
```

---

### Task 2: web-ifc の vendoring とネイティブビルドスクリプト

**Files:**
- Create: `vendor/web-ifc`（git submodule）
- Create: `scripts/build-webifc.sh`

**Interfaces:**
- Produces: `.webifc/lib/libweb-ifc.a`（統合静的ライブラリ）と `.webifc/include/web-ifc/`（web-ifc ヘッダツリー）+ `.webifc/include/glm` 等の依存ヘッダ。以降の全 C++ コンパイルはこの 2 パスだけを参照する

- [ ] **Step 1: 前提ツール確認と submodule 追加**

```bash
which cmake || brew install cmake
which xcodegen || brew install xcodegen
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook submodule add https://github.com/ThatOpen/engine_web-ifc.git vendor/web-ifc
# 最新の安定タグに固定する（git -C vendor/web-ifc tag --sort=-v:refname | head でタグ一覧を確認し、最新の安定版に checkout して記録する）
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook/vendor/web-ifc tag --sort=-v:refname | head -5
```

期待: submodule が追加され、タグ一覧が表示される。表示された最新安定タグ（例 `v0.0.69`）に `git -C vendor/web-ifc checkout <tag>` で固定。

- [ ] **Step 2: ビルドスクリプトを書く**

`scripts/build-webifc.sh`:

```bash
#!/bin/bash
# web-ifc をネイティブ静的ライブラリとしてビルドし、.webifc/{lib,include} に集約する。
# 冪等: 再実行すると作り直す。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/web-ifc"
BUILD="$ROOT/build/webifc"
OUT="$ROOT/.webifc"

# upstream の CMake でネイティブビルド（Emscripten なし）
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_CXX_STANDARD=20
cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"

# 生成された静的ライブラリ（web-ifc 本体 + 依存）を 1 本に統合
LIBS=$(find "$BUILD" -name '*.a')
echo "統合対象: $LIBS"
libtool -static -o "$OUT/lib/libweb-ifc.a" $LIBS

# ヘッダ集約: web-ifc 本体（src/cpp 以下を web-ifc/ プレフィックスで）
rsync -a --include='*/' --include='*.h' --include='*.hpp' --exclude='*' \
  "$SRC/src/cpp/" "$OUT/include/web-ifc/"

# ヘッダ集約: FetchContent で落ちた依存（glm 等）。*-src ディレクトリからヘッダのみコピー
for dep in "$BUILD"/_deps/*-src; do
  name=$(basename "$dep" | sed 's/-src$//')
  # glm はルートに glm/ を持つ / earcut は include/ を持つ 等、代表的レイアウトを吸収
  if [ -d "$dep/glm" ]; then rsync -a "$dep/glm" "$OUT/include/"
  elif [ -d "$dep/include" ]; then rsync -a "$dep/include/" "$OUT/include/"
  else rsync -a --include='*/' --include='*.h' --include='*.hpp' --exclude='*' "$dep/" "$OUT/include/$name/"
  fi
done

echo "OK: $OUT/lib/libweb-ifc.a"
lipo -info "$OUT/lib/libweb-ifc.a" || true
```

- [ ] **Step 3: 実行して成果物を確認**

実行: `chmod +x scripts/build-webifc.sh && ./scripts/build-webifc.sh`（初回は FetchContent のダウンロードを含むため数分かかる。10 分超えたら中断して原因調査）

期待:
- `OK: .../.webifc/lib/libweb-ifc.a` が出力される
- `ls .webifc/include/web-ifc/parsing/IfcLoader.h .webifc/include/web-ifc/geometry/IfcGeometryProcessor.h .webifc/include/web-ifc/schema/IfcSchemaManager.h` が全て存在する

※ upstream の CMake オプション名やターゲット構成はバージョンで変わりうる。cmake configure が失敗した場合は `vendor/web-ifc/CMakeLists.txt` 冒頭の option() 群と `README.md` のネイティブビルド手順を読み、スクリプトのオプションを合わせる（スクリプトを修正して正とする）。

- [ ] **Step 4: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add .gitmodules vendor/web-ifc scripts/build-webifc.sh
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "build: web-ifc submodule とネイティブ静的ライブラリのビルドスクリプト"
```

---

### Task 3: C++ smoke テスト — web-ifc API 疎通（M1 完了点）

**Files:**
- Create: `Bridge/smoke/test_load.cpp`

**Interfaces:**
- Produces: web-ifc の実 API 呼び出しパターン（Loader 構築 → LoadFile → GetFlatMesh ループ）。Task 4 の WebIFCBridge.mm はこのファイルで確定したシグネチャをそのまま使う

- [ ] **Step 1: smoke テストを書く（このコンパイルが「失敗するテスト」に相当）**

`Bridge/smoke/test_load.cpp`:

```cpp
// web-ifc ネイティブ API の疎通確認。fixture を読み三角形数を出力する。
// ここで確定した API 呼び出しパターンが WebIFCBridge.mm の正となる。
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include "web-ifc/parsing/IfcLoader.h"
#include "web-ifc/schema/IfcSchemaManager.h"
#include "web-ifc/geometry/IfcGeometryProcessor.h"

int main(int argc, char **argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s file.ifc\n", argv[0]); return 2; }
    std::ifstream ifs(argv[1], std::ios::binary);
    std::stringstream ss; ss << ifs.rdbuf();
    const std::string content = ss.str();

    webifc::schema::IfcSchemaManager schemas;
    // (tapeSize, memoryLimit, lineWriterBuffer) は upstream の既定値に準拠
    webifc::parsing::IfcLoader loader(64 * 1024 * 1024, 2ull << 30, 10000, schemas);
    loader.LoadFile([&](char *dest, size_t sourceOffset, size_t destSize) -> uint32_t {
        if (sourceOffset >= content.size()) return 0;
        size_t n = std::min(destSize, content.size() - sourceOffset);
        std::memcpy(dest, content.data() + sourceOffset, n);
        return static_cast<uint32_t>(n);
    });

    // circleSegments=12, coordinateToOrigin=true（巨大座標を原点に寄せ float 精度を守る）
    webifc::geometry::IfcGeometryProcessor processor(loader, schemas, 12, true);
    size_t triangles = 0, elements = 0;
    for (auto type : schemas.GetIfcElementList()) {
        for (auto eid : loader.GetExpressIDsWithType(type)) {
            auto flat = processor.GetFlatMesh(eid);
            bool hasGeom = false;
            for (auto &pg : flat.geometries) {
                auto &geom = processor.GetGeometry(pg.geometryExpressID);
                triangles += geom.GetIndexDataSize() / 3;
                hasGeom = hasGeom || geom.GetIndexDataSize() > 0;
            }
            if (hasGeom) elements++;
        }
    }
    std::printf("elements=%zu triangles=%zu\n", elements, triangles);
    return triangles > 0 ? 0 : 1;
}
```

- [ ] **Step 2: コンパイルして失敗/成功を確認**

実行:

```bash
mkdir -p build
clang++ -std=c++20 -O2 \
  -I .webifc/include -I .webifc/include/web-ifc \
  Bridge/smoke/test_load.cpp .webifc/lib/libweb-ifc.a \
  -o build/test_load
```

コンパイルエラーが出た場合（コンストラクタ引数・メソッド名のバージョン差）は `vendor/web-ifc/src/cpp/` 内のテスト/サンプルコード（`*.cpp` で `IfcLoader` を grep）の使用例に合わせて `test_load.cpp` を修正する。**修正後のコードが Task 4 以降の正**。

- [ ] **Step 3: fixture で実行して三角形数を確認**

実行: `./build/test_load Tests/Fixtures/minimal_wall.ifc`
期待: `elements=1 triangles=12`（直方体 = 12 三角形。web-ifc のテッセレーション差で ±α は許容、`triangles>0` かつ exit 0 が必須）

fixture 側のパースエラーだった場合は Task 1 Step 2 の注記どおり fixture を修正する。

- [ ] **Step 4: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add Bridge/smoke/test_load.cpp Tests/Fixtures/minimal_wall.ifc
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: web-ifcネイティブAPIのsmoke検証（M1: エンジン疎通）"
```

---

### Task 4: Xcode プロジェクト（XcodeGen）+ WebIFCBridge（Obj-C++）+ 単体テスト

**Files:**
- Create: `project.yml`
- Create: `Bridge/WebIFCBridge.h`
- Create: `Bridge/WebIFCBridge.mm`
- Create: `Bridge/IFCQuickLook-Bridging-Header.h`
- Create: `App/Main.swift`（仮の空アプリ。Task 7 で本実装）
- Create: `App/App-Info.plist` / `App/App.entitlements`（UTI 宣言は Task 9 で追記）
- Test: `Tests/WebIFCBridgeTests.swift`
- Test: `Tests/Fixtures/broken.ifc`

**Interfaces:**
- Produces: `WebIFCBridge.streamMeshes(fromFileAtPath:handler:) throws -> IFCModelInfo`、`IFCMeshChunk`、`IFCModelInfo`、エラー定数（下記）— 以降の全タスクが消費

- [ ] **Step 1: project.yml を書く**

```yaml
name: IFCQuickLook
options:
  bundleIdPrefix: jp.trapple
  createIntermediateGroups: true
settings:
  base:
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    SWIFT_VERSION: "5.0"                 # 言語モード5（strict concurrency を強制しない）
    CLANG_CXX_LANGUAGE_STANDARD: c++20
    HEADER_SEARCH_PATHS:
      - $(PROJECT_DIR)/.webifc/include
      - $(PROJECT_DIR)/.webifc/include/web-ifc
    LIBRARY_SEARCH_PATHS:
      - $(PROJECT_DIR)/.webifc/lib
    OTHER_LDFLAGS: ["-lweb-ifc", "-lc++"]
    SWIFT_OBJC_BRIDGING_HEADER: Bridge/IFCQuickLook-Bridging-Header.h
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"              # ローカル ad-hoc。配布時に Developer ID へ
targets:
  IFCQuickLook:
    type: application
    platform: macOS
    sources: [App, Shared, Bridge/WebIFCBridge.h, Bridge/WebIFCBridge.mm]
    info:
      path: App/App-Info.plist
      properties:
        NSPrincipalClass: NSApplication
    entitlements:
      path: App/App.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.files.user-selected.read-only: true
    dependencies:
      - target: IFCPreview
        embed: true
  IFCPreview:
    type: app-extension
    platform: macOS
    sources: [PreviewExtension, Shared, Bridge/WebIFCBridge.h, Bridge/WebIFCBridge.mm]
    info:
      path: PreviewExtension/PreviewExtension-Info.plist
      properties: {}   # NSExtension 定義は Task 9 で追記
    entitlements:
      path: PreviewExtension/PreviewExtension.entitlements
      properties:
        com.apple.security.app-sandbox: true
  ifcql-bench:
    type: tool
    platform: macOS
    sources: [Bench, Shared, Bridge/WebIFCBridge.h, Bridge/WebIFCBridge.mm]
  IFCCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests
      - Shared
      - Bridge/WebIFCBridge.h
      - Bridge/WebIFCBridge.mm
    settings:
      base:
        # fixture をテストバンドルに同梱
        {}
```

※ `Tests/Fixtures` は XcodeGen の `sources` で `buildPhase: resources` を指定して同梱する:

```yaml
    sources:
      - path: Tests
        excludes: ["Fixtures/**"]
      - path: Tests/Fixtures
        buildPhase: resources
      - Shared
      - Bridge/WebIFCBridge.h
      - Bridge/WebIFCBridge.mm
```

（IFCCoreTests の sources はこの形を正とする。Task 7 までは `Shared/` が未作成でも XcodeGen は空ディレクトリを無視するため、`mkdir -p Shared Bench PreviewExtension` で空ディレクトリを作ってから generate する。ただし各ターゲットに最低 1 ソースが必要なので、このタスクでは `Bench/main.swift` に `print("stub")`、`PreviewExtension/PreviewViewController.swift` に空クラスの stub を置く）

- [ ] **Step 2: 失敗するテストを書く**

`Tests/WebIFCBridgeTests.swift`:

```swift
import XCTest

/// テストバンドル同梱 fixture の URL を返す
func fixtureURL(_ name: String, ext: String = "ifc") -> URL {
    Bundle(for: WebIFCBridgeTests.self).url(forResource: name, withExtension: ext)!
}

final class WebIFCBridgeTests: XCTestCase {

    /// 最小fixture: 壁1枚がメッシュとしてストリームされること
    func testMinimalWallStreamsTriangles() throws {
        var chunks: [IFCMeshChunk] = []
        let bridge = WebIFCBridge()
        let info = try bridge.streamMeshes(fromFileAtPath: fixtureURL("minimal_wall").path) { chunks.append($0) }
        XCTAssertEqual(info.schemaVersion, "IFC4")
        XCTAssertEqual(info.elementCount, 1)
        let triangles = chunks.reduce(0) { $0 + Int($1.indexCount) / 3 }
        XCTAssertGreaterThanOrEqual(triangles, 12)
        // 頂点は 6 float インターリーブ
        XCTAssertEqual(chunks[0].vertexData.count, Int(chunks[0].vertexCount) * 6 * MemoryLayout<Float>.size)
    }

    /// 壊れたファイル → parseFailed で throw（Fail Fast）
    func testBrokenFileThrows() {
        let bridge = WebIFCBridge()
        XCTAssertThrowsError(try bridge.streamMeshes(fromFileAtPath: fixtureURL("broken").path) { _ in }) { error in
            XCTAssertEqual((error as NSError).domain, IFCBridgeErrorDomain)
        }
    }

    /// 存在しないパス → cantOpen
    func testMissingFileThrows() {
        let bridge = WebIFCBridge()
        XCTAssertThrowsError(try bridge.streamMeshes(fromFileAtPath: "/nonexistent/x.ifc") { _ in })
    }
}
```

`Tests/Fixtures/broken.ifc`:

```
THIS IS NOT AN IFC FILE. QUICK LOOK SHOULD SHOW AN ERROR.
```

- [ ] **Step 3: WebIFCBridge のヘッダを書く**

`Bridge/WebIFCBridge.h`:

```objc
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
/// 配置変換は適用済み（Y-up・原点寄せ済みの最終座標）。
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
                                                error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
```

`Bridge/IFCQuickLook-Bridging-Header.h`:

```objc
#import "WebIFCBridge.h"
```

- [ ] **Step 4: WebIFCBridge.mm を実装（Task 3 で確定した API パターンを使用）**

`Bridge/WebIFCBridge.mm`:

```objc
#import "WebIFCBridge.h"
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

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
    NSData *_vertexData; NSData *_indexData; simd_float4 _color;
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

@implementation IFCModelInfo {
    NSString *_schema; NSUInteger _count;
}
- (instancetype)initWithSchema:(NSString *)s elementCount:(NSUInteger)c {
    if ((self = [super init])) { _schema = s; _count = c; }
    return self;
}
- (NSString *)schemaVersion { return _schema; }
- (NSUInteger)elementCount { return _count; }
@end

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
    return [[NSString alloc] initWithBytes:head.data() + q1 + 1 length:q2 - q1 - 1 encoding:NSASCIIStringEncoding];
}

static NSError *MakeError(IFCBridgeError code, NSString *msg) {
    return [NSError errorWithDomain:IFCBridgeErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : msg}];
}

@implementation WebIFCBridge

- (nullable IFCModelInfo *)streamMeshesFromFileAtPath:(NSString *)path
                                              handler:(void (NS_NOESCAPE ^)(IFCMeshChunk *))handler
                                                error:(NSError **)error {
    // --- mmap（コピーせず web-ifc に渡す） ---
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        if (error) *error = MakeError(IFCBridgeErrorCantOpen, [NSString stringWithFormat:@"ファイルを開けません: %@", path]);
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
        if (error) *error = MakeError(IFCBridgeErrorParseFailed, @"IFC ヘッダ（FILE_SCHEMA）が見つかりません。IFC ファイルではない可能性があります");
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
    size_t totalTriangles = 0;
    try {
        webifc::schema::IfcSchemaManager schemas;
        webifc::parsing::IfcLoader loader(64 * 1024 * 1024, 2ull << 30, 10000, schemas);
        loader.LoadFile([&](char *dest, size_t sourceOffset, size_t destSize) -> uint32_t {
            if (sourceOffset >= fileSize) return 0;
            size_t n = std::min(destSize, fileSize - sourceOffset);
            memcpy(dest, bytes + sourceOffset, n);
            return (uint32_t)n;
        });

        webifc::geometry::IfcGeometryProcessor processor(loader, schemas, 12, /*coordinateToOrigin*/ true);
        std::vector<float> vbuf; // 再利用バッファ

        for (auto type : schemas.GetIfcElementList()) {
            for (auto eid : loader.GetExpressIDsWithType(type)) {
                auto flat = processor.GetFlatMesh(eid);
                bool emitted = false;
                for (auto &pg : flat.geometries) {
                    auto &geom = processor.GetGeometry(pg.geometryExpressID);
                    const size_t vCount = geom.GetVertexDataSize() / 6; // 6 double / 頂点
                    const size_t iCount = geom.GetIndexDataSize();
                    if (vCount == 0 || iCount == 0) continue;

                    // 配置変換を適用しつつ double → float へ（法線は逆転置行列）
                    const double *vd = geom.GetVertexData();
                    const glm::dmat4 M = pg.flatTransformation;
                    const glm::dmat3 N = glm::transpose(glm::inverse(glm::dmat3(M)));
                    vbuf.resize(vCount * 6);
                    for (size_t v = 0; v < vCount; v++) {
                        glm::dvec4 p = M * glm::dvec4(vd[v*6+0], vd[v*6+1], vd[v*6+2], 1.0);
                        glm::dvec3 nrm = glm::normalize(N * glm::dvec3(vd[v*6+3], vd[v*6+4], vd[v*6+5]));
                        vbuf[v*6+0] = (float)p.x; vbuf[v*6+1] = (float)p.y; vbuf[v*6+2] = (float)p.z;
                        vbuf[v*6+3] = (float)nrm.x; vbuf[v*6+4] = (float)nrm.y; vbuf[v*6+5] = (float)nrm.z;
                    }
                    NSData *vData = [NSData dataWithBytes:vbuf.data() length:vbuf.size() * sizeof(float)];
                    NSData *iData = [NSData dataWithBytes:geom.GetIndexData() length:iCount * sizeof(uint32_t)];
                    simd_float4 color = simd_make_float4((float)pg.color.r, (float)pg.color.g,
                                                         (float)pg.color.b, (float)pg.color.a);
                    handler([[IFCMeshChunk alloc] initWithVertexData:vData indexData:iData color:color]);
                    totalTriangles += iCount / 3;
                    emitted = true;
                }
                if (emitted) elementCount++;
            }
        }
    } catch (const std::exception &e) {
        munmap(mapped, fileSize);
        if (error) *error = MakeError(IFCBridgeErrorParseFailed,
            [NSString stringWithFormat:@"パースに失敗しました: %s", e.what()]);
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
    return [[IFCModelInfo alloc] initWithSchema:upper elementCount:elementCount];
}

@end
```

※ `GetVertexData()/GetIndexData()/flatTransformation/color` の型・メンバ名が Task 3 で確定した実 API と異なる場合は Task 3 の `test_load.cpp` を正として合わせる。

- [ ] **Step 5: stub ファイルを置いてプロジェクト生成、テスト実行 → 失敗確認**

```bash
mkdir -p Shared Bench PreviewExtension
printf 'print("stub")\n' > Bench/main.swift
printf 'import Foundation\n// Task 9 で実装\nfinal class PreviewStub {}\n' > PreviewExtension/PreviewViewController.swift
printf 'import AppKit\n// Task 7 で実装\nlet app = NSApplication.shared\napp.run()\n' > App/Main.swift
xcodegen generate
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests test 2>&1 | tail -20
```

期待: 初回はビルドエラー or テスト失敗（実装とテストを同時に足しているため、ここは「全テスト PASS まで直す」の起点として扱う）。リンクエラー（シンボル欠落）が出たら `.webifc/lib/libweb-ifc.a` の統合漏れを疑い `nm` で確認。

- [ ] **Step 6: テスト通過を確認**

実行: `xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests test 2>&1 | tail -5`
期待: `** TEST SUCCEEDED **`（3 テスト全部 PASS）

- [ ] **Step 7: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add project.yml Bridge App Bench PreviewExtension Tests
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: XcodeプロジェクトとWebIFCBridge(Obj-C++シム)を実装"
```

---

### Task 5: MeshBatcher — 色別統合・三角形上限・AABB

**Files:**
- Create: `Shared/MeshBatcher.swift`
- Test: `Tests/MeshBatcherTests.swift`

**Interfaces:**
- Consumes: `IFCMeshChunk`（Task 4）
- Produces: `AABB`, `MaterialBatch`, `MeshBatcher`（冒頭の Interfaces 全体図どおり）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MeshBatcherTests.swift`:

```swift
import XCTest
import simd

/// テスト用チャンク生成: 1 三角形 (0,0,0)(1,0,0)(0,1,0)、法線+Z
func makeChunk(color: SIMD4<Float>, offset: Float = 0) -> IFCMeshChunk {
    let v: [Float] = [
        0 + offset, 0, 0, 0, 0, 1,
        1 + offset, 0, 0, 0, 0, 1,
        0 + offset, 1, 0, 0, 0, 1,
    ]
    let i: [UInt32] = [0, 1, 2]
    return IFCMeshChunk(
        vertexData: v.withUnsafeBufferPointer { Data(buffer: $0) },
        indexData: i.withUnsafeBufferPointer { Data(buffer: $0) },
        color: color)
}

final class MeshBatcherTests: XCTestCase {

    /// 同色チャンクは 1 バッチに統合され、インデックスがオフセットされる
    func testMergesSameColor() {
        let batcher = MeshBatcher(triangleLimit: 100)
        let red = SIMD4<Float>(1, 0, 0, 1)
        XCTAssertTrue(batcher.add(makeChunk(color: red)))
        XCTAssertTrue(batcher.add(makeChunk(color: red, offset: 5)))
        let batches = batcher.drain()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].vertices.count, 6 * 6)      // 6 頂点
        XCTAssertEqual(batches[0].indices, [0, 1, 2, 3, 4, 5]) // 2個目は +3 オフセット
        XCTAssertEqual(batcher.totalTriangles, 2)
    }

    /// 異なる色は別バッチ
    func testSplitsByColor() {
        let batcher = MeshBatcher(triangleLimit: 100)
        batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1)))
        batcher.add(makeChunk(color: SIMD4<Float>(0, 1, 0, 1)))
        XCTAssertEqual(batcher.drain().count, 2)
    }

    /// 三角形上限を超えるチャンクはスキップされ、skippedElements が増える（silent にしない）
    func testTriangleLimitSkips() {
        let batcher = MeshBatcher(triangleLimit: 1)
        XCTAssertTrue(batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1))))
        XCTAssertFalse(batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1))))
        XCTAssertEqual(batcher.skippedElements, 1)
        XCTAssertEqual(batcher.totalTriangles, 1)
    }

    /// AABB は drain を跨いで累積する
    func testBoundsAccumulateAcrossDrains() {
        let batcher = MeshBatcher(triangleLimit: 100)
        batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1)))
        _ = batcher.drain()
        batcher.add(makeChunk(color: SIMD4<Float>(1, 0, 0, 1), offset: 9))
        _ = batcher.drain()
        let b = try! XCTUnwrap(batcher.bounds)
        XCTAssertEqual(b.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(b.max, SIMD3<Float>(10, 1, 0))
    }
}
```

- [ ] **Step 2: 実行して失敗を確認**

実行: `xcodegen generate && xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests/MeshBatcherTests test 2>&1 | tail -5`
期待: FAIL（`MeshBatcher` 未定義のコンパイルエラー）

- [ ] **Step 3: 最小実装**

`Shared/MeshBatcher.swift`:

```swift
import Foundation
import simd

/// 軸並行バウンディングボックス
struct AABB {
    var min: SIMD3<Float>
    var max: SIMD3<Float>
    mutating func union(_ p: SIMD3<Float>) {
        min = simd.min(min, p)
        max = simd.max(max, p)
    }
    var center: SIMD3<Float> { (min + max) * 0.5 }
    var size: SIMD3<Float> { max - min }
}

/// 色ごとに統合されたメッシュ（RKSceneBuilder が MeshResource 化する単位）
struct MaterialBatch {
    let color: SIMD4<Float>
    var vertices: [Float]    // position+normal 6 float インターリーブ
    var indices: [UInt32]
    var vertexCount: Int { vertices.count / 6 }
}

/// IFCMeshChunk を色別に統合し、三角形上限と AABB を管理する。
/// スレッド非対応（呼び出し側が単一スレッドで使う）。
final class MeshBatcher {
    let triangleLimit: Int
    private var open: [UInt32: MaterialBatch] = [:] // RGBA8 量子化キー
    private(set) var totalTriangles = 0
    private(set) var skippedElements = 0
    private(set) var bounds: AABB?

    init(triangleLimit: Int = 20_000_000) {
        self.triangleLimit = triangleLimit
    }

    /// 追加できたら true。上限超過はスキップして false（skippedElements に計上）。
    @discardableResult
    func add(_ chunk: IFCMeshChunk) -> Bool {
        let tris = Int(chunk.indexCount) / 3
        guard totalTriangles + tris <= triangleLimit else {
            skippedElements += 1
            return false
        }
        let key = Self.quantize(chunk.color)
        var batch = open[key] ?? MaterialBatch(color: chunk.color, vertices: [], indices: [])
        let base = UInt32(batch.vertexCount)

        chunk.vertexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            batch.vertices.append(contentsOf: floats)
            // AABB 更新（position のみ）
            var b = bounds
            var v = 0
            while v < floats.count {
                let p = SIMD3<Float>(floats[v], floats[v + 1], floats[v + 2])
                if b == nil { b = AABB(min: p, max: p) } else { b!.union(p) }
                v += 6
            }
            bounds = b
        }
        chunk.indexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let idx = raw.bindMemory(to: UInt32.self)
            batch.indices.reserveCapacity(batch.indices.count + idx.count)
            for i in idx { batch.indices.append(i + base) }
        }
        open[key] = batch
        totalTriangles += tris
        return true
    }

    /// 溜まったバッチを取り出して内部状態をリセット（プログレッシブ表示用）。
    /// bounds / totalTriangles / skippedElements は累積のまま。
    func drain() -> [MaterialBatch] {
        let result = Array(open.values)
        open.removeAll(keepingCapacity: true)
        return result
    }

    /// RGBA を 8bit 量子化してキー化（微小な色差は同一マテリアル扱い）
    private static func quantize(_ c: SIMD4<Float>) -> UInt32 {
        let r = UInt32(simd_clamp(c.x, 0, 1) * 255)
        let g = UInt32(simd_clamp(c.y, 0, 1) * 255)
        let b = UInt32(simd_clamp(c.z, 0, 1) * 255)
        let a = UInt32(simd_clamp(c.w, 0, 1) * 255)
        return (r << 24) | (g << 16) | (b << 8) | a
    }
}
```

- [ ] **Step 4: テスト通過を確認**

実行: `xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests test 2>&1 | tail -5`
期待: `** TEST SUCCEEDED **`（Bridge テスト含め全 PASS）

- [ ] **Step 5: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add Shared/MeshBatcher.swift Tests/MeshBatcherTests.swift
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: MeshBatcher（色別統合・三角形上限・AABB）"
```

---

### Task 6: ifcql-bench CLI — 性能計測基盤

**Files:**
- Modify: `Bench/main.swift`（stub を置換）

**Interfaces:**
- Consumes: `WebIFCBridge`, `MeshBatcher`
- Produces: `ifcql-bench <file.ifc>` — `schema= elements= triangles= colors= parse_s= peak_mem_mb=` を 1 行出力

- [ ] **Step 1: 実装（CLI は目視検証のためテストより実装が先で OK）**

`Bench/main.swift`:

```swift
// ifcql-bench: パース時間・三角形数・ピークメモリを計測する CLI。
// 性能回帰チェックに使う（QL 拡張を経由せずコアだけを測る）。
import Foundation

/// プロセスのピーク物理メモリ (MB)
func peakMemoryMB() -> Double {
    var info = rusage_info_current()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
        }
    }
    guard ok == 0 else { return -1 }
    return Double(info.ri_lifetime_max_phys_footprint) / 1024 / 1024
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: ifcql-bench <file.ifc>\n".data(using: .utf8)!)
    exit(2)
}
let path = CommandLine.arguments[1]

let start = ContinuousClock.now
let batcher = MeshBatcher()
let bridge = WebIFCBridge()
do {
    let info = try bridge.streamMeshes(fromFileAtPath: path) { batcher.add($0) }
    let batches = batcher.drain()
    let seconds = Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000
    print("schema=\(info.schemaVersion) elements=\(info.elementCount) " +
          "triangles=\(batcher.totalTriangles) colors=\(batches.count) " +
          "skipped=\(batcher.skippedElements) " +
          String(format: "parse_s=%.2f peak_mem_mb=%.0f", seconds, peakMemoryMB()))
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
```

- [ ] **Step 2: ビルドして fixture で実行**

```bash
xcodegen generate
xcodebuild -project IFCQuickLook.xcodeproj -scheme ifcql-bench -derivedDataPath build/dd build 2>&1 | tail -3
./build/dd/Build/Products/Debug/ifcql-bench Tests/Fixtures/minimal_wall.ifc
```

期待: `schema=IFC4 elements=1 triangles=12 colors=1 skipped=0 parse_s=0.0x peak_mem_mb=xx`

- [ ] **Step 3: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add Bench/main.swift
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: ifcql-bench CLI（時間・三角形数・ピークメモリ計測）"
```

---

### Task 7: RealityKit ビューア（RKSceneBuilder + OrbitCamera + ViewerViewController + App）— M2 完了点

**Files:**
- Create: `Shared/RKSceneBuilder.swift`
- Create: `Shared/OrbitCameraController.swift`
- Create: `Shared/ViewerARView.swift`
- Create: `Shared/ViewerViewController.swift`
- Modify: `App/Main.swift`（stub を置換: Open メニュー + ビューアウィンドウ）

**Interfaces:**
- Consumes: `MaterialBatch`, `AABB`, `ModelLoader`（※ ModelLoader は Task 8。本タスクでは `ViewerViewController.start(url:)` の中身を単発ロード（`drain()` 一括）で仮実装し、Task 8 でプログレッシブに差し替える）
- Produces: `RKSceneBuilder.makeEntities(_:)`, `OrbitCameraController`, `ViewerViewController`（`start(url:)` / `show(message:)`）

- [ ] **Step 1: RKSceneBuilder を書く**

`Shared/RKSceneBuilder.swift`:

```swift
import Foundation
import RealityKit
import AppKit

/// MaterialBatch → ModelEntity 変換（色ごとに 1 エンティティ = 1 ドローコール相当）
enum RKSceneBuilder {
    static func makeEntities(_ batches: [MaterialBatch]) -> [ModelEntity] {
        batches.compactMap { batch in
            guard batch.vertexCount > 0 else { return nil }
            var positions = [SIMD3<Float>](); positions.reserveCapacity(batch.vertexCount)
            var normals = [SIMD3<Float>](); normals.reserveCapacity(batch.vertexCount)
            var v = 0
            while v < batch.vertices.count {
                positions.append(SIMD3(batch.vertices[v], batch.vertices[v+1], batch.vertices[v+2]))
                normals.append(SIMD3(batch.vertices[v+3], batch.vertices[v+4], batch.vertices[v+5]))
                v += 6
            }
            var desc = MeshDescriptor()
            desc.positions = MeshBuffer(positions)
            desc.normals = MeshBuffer(normals)
            desc.primitives = .triangles(batch.indices)
            guard let mesh = try? MeshResource.generate(from: [desc]) else { return nil }

            var material = PhysicallyBasedMaterial()
            let c = batch.color
            material.baseColor = .init(tint: NSColor(red: CGFloat(c.x), green: CGFloat(c.y),
                                                     blue: CGFloat(c.z), alpha: 1.0))
            material.roughness = 0.8
            material.metallic = 0.0
            if c.w < 0.999 {
                // 半透明（ガラス等）: アルファブレンド
                material.blending = .transparent(opacity: .init(floatLiteral: c.w))
            }
            return ModelEntity(mesh: mesh, materials: [material])
        }
    }
}
```

- [ ] **Step 2: OrbitCameraController を書く**

`Shared/OrbitCameraController.swift`:

```swift
import Foundation
import RealityKit
import simd

/// 球面座標オービットカメラ。yaw/pitch/distance/target を保持し Entity に適用する。
final class OrbitCameraController {
    var yaw: Float = .pi / 4          // 斜め 45°
    var pitch: Float = .pi / 6        // 見下ろし 30°
    var distance: Float = 10
    var target = SIMD3<Float>(0, 0, 0)

    private var minDistance: Float = 0.1
    private var maxDistance: Float = 10_000

    /// bbox 全体が収まるよう注視点と距離を設定（初期視点: 斜め上 45° の等角風）
    func frame(_ bbox: AABB) {
        target = bbox.center
        let radius = simd_length(bbox.size) * 0.5
        distance = max(radius * 2.2, 0.5)
        minDistance = max(radius * 0.01, 0.01)
        maxDistance = radius * 20
    }

    func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = simd_clamp(pitch + dy * 0.008, -.pi / 2 + 0.05, .pi / 2 - 0.05)
    }

    func zoom(delta: Float) {
        distance = simd_clamp(distance * exp(-delta * 0.1), minDistance, maxDistance)
    }

    func pan(dx: Float, dy: Float) {
        let rot = rotation
        let right = rot.act(SIMD3<Float>(1, 0, 0))
        let up = rot.act(SIMD3<Float>(0, 1, 0))
        let k = distance * 0.0015
        target += right * (-dx * k) + up * (dy * k)
    }

    private var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
    }

    /// カメラエンティティへ適用。カメラの -Z が target を向く。
    func apply(to entity: Entity) {
        let rot = rotation
        let position = target + rot.act(SIMD3<Float>(0, 0, distance))
        entity.transform = Transform(scale: .one, rotation: rot, translation: position)
    }
}
```

- [ ] **Step 3: ViewerARView（イベント処理）を書く**

`Shared/ViewerARView.swift`:

```swift
import AppKit
import RealityKit

/// マウス/スクロール/ピンチをオービットカメラ操作に変換する ARView（macOS・非AR）。
final class ViewerARView: ARView {
    var onOrbit: ((Float, Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onPan: ((Float, Float) -> Void)?

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            onPan?(Float(event.deltaX), Float(event.deltaY))
        } else {
            onOrbit?(Float(event.deltaX), Float(event.deltaY))
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        onPan?(Float(event.deltaX), Float(event.deltaY))
    }
    override func scrollWheel(with event: NSEvent) {
        onZoom?(Float(event.scrollingDeltaY) * 0.1)
    }
    override func magnify(with event: NSEvent) {
        onZoom?(Float(event.magnification) * 10)
    }
}
```

- [ ] **Step 4: ViewerViewController を書く（ロードは仮実装: 一括）**

`Shared/ViewerViewController.swift`:

```swift
import AppKit
import RealityKit

/// 3D ビューア本体。App の単体ビューアと QL 拡張の両方から使う。
final class ViewerViewController: NSViewController {
    private let arView = ViewerARView(frame: .zero)
    private let cameraEntity = PerspectiveCamera()
    private let cameraController = OrbitCameraController()
    private let modelRoot = Entity()
    private let overlayLabel = NSTextField(labelWithString: "読み込み中…")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        arView.frame = view.bounds
        arView.autoresizingMask = [.width, .height]
        arView.environment.background = .color(.underPageBackgroundColor)
        view.addSubview(arView)

        // シーングラフ: モデルルート + カメラ + 平行光源
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(modelRoot)
        let light = DirectionalLight()
        light.light.intensity = 5_000
        light.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0.3, 0])
        anchor.addChild(light)
        anchor.addChild(cameraEntity)
        arView.scene.addAnchor(anchor)
        cameraController.apply(to: cameraEntity)

        // カメラ操作をバインド
        arView.onOrbit = { [weak self] dx, dy in self?.updateCamera { $0.orbit(dx: dx, dy: dy) } }
        arView.onZoom = { [weak self] d in self?.updateCamera { $0.zoom(delta: d) } }
        arView.onPan = { [weak self] dx, dy in self?.updateCamera { $0.pan(dx: dx, dy: dy) } }

        // HUD オーバーレイ（左下）
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayLabel)
        // エラービュー（中央・初期非表示）
        errorLabel.textColor = .labelColor
        errorLabel.font = .systemFont(ofSize: 14)
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            overlayLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            overlayLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    private func updateCamera(_ mutate: (OrbitCameraController) -> Void) {
        mutate(cameraController)
        cameraController.apply(to: cameraEntity)
    }

    /// エラー表示（Fail Fast: 理由を明示し 3D ビューを隠す）
    func show(message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        overlayLabel.isHidden = true
        arView.isHidden = true
    }

    /// バッチをシーンに追加
    func append(batches: [MaterialBatch]) {
        for entity in RKSceneBuilder.makeEntities(batches) {
            modelRoot.addChild(entity)
        }
    }

    /// 読み込み完了: カメラフレーミングとサマリ表示
    func finish(summary: LoadSummary) {
        if let bounds = summary.bounds {
            cameraController.frame(bounds)
            cameraController.apply(to: cameraEntity)
        }
        var text = "\(summary.schema)  要素 \(summary.elementCount)  三角形 \(summary.triangleCount)  " +
                   String(format: "%.1fs", summary.seconds)
        if summary.skippedElements > 0 {
            text = "⚠︎ \(summary.skippedElements)要素を省略（上限超過）  " + text
        }
        overlayLabel.stringValue = text
    }

    /// ロード開始（Task 8 で ModelLoader によるプログレッシブ版に差し替える。ここは仮の一括版）
    func start(url: URL) {
        let started = ContinuousClock.now
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let batcher = MeshBatcher()
            do {
                let info = try WebIFCBridge().streamMeshes(fromFileAtPath: url.path) { batcher.add($0) }
                let batches = batcher.drain()
                let seconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
                let summary = LoadSummary(schema: info.schemaVersion, elementCount: Int(info.elementCount),
                                          triangleCount: batcher.totalTriangles,
                                          skippedElements: batcher.skippedElements,
                                          seconds: seconds, bounds: batcher.bounds)
                DispatchQueue.main.async {
                    self?.append(batches: batches)
                    self?.finish(summary: summary)
                }
            } catch {
                DispatchQueue.main.async { self?.show(message: error.localizedDescription) }
            }
        }
    }
}

/// 読み込み結果サマリ（Task 8 の ModelLoader と共有する型をここで定義）
struct LoadSummary {
    let schema: String
    let elementCount: Int
    let triangleCount: Int
    let skippedElements: Int
    let seconds: Double
    let bounds: AABB?
}
```

- [ ] **Step 5: App/Main.swift を本実装（Open メニュー + ウィンドウ）**

`App/Main.swift`:

```swift
// ホストアプリ: QL 拡張の入れ物 + 開発用の単体ビューア。
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = menu
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openViewer)
    }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []  // 拡張子フィルタは緩め（UTI 未登録環境でも開けるように）
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { openViewer(url) }
    }

    private func openViewer(_ url: URL) {
        let vc = ViewerViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        vc.start(url: url)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
```

- [ ] **Step 6: ビルドして単体ビューアで目視確認**

```bash
xcodegen generate
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -derivedDataPath build/dd build 2>&1 | tail -3
open build/dd/Build/Products/Debug/IFCQuickLook.app --args "$(pwd)/Tests/Fixtures/minimal_wall.ifc"
```

（`open --args` でパスが渡らない場合は File > Open… から fixture を選ぶ）

期待（目視チェックリスト）:
- 壁（横長の直方体）が表示される
- ドラッグで回転 / スクロールでズーム / Shift+ドラッグでパンが機能する
- 左下 HUD に `IFC4  要素 1  三角形 12  0.xs` が出る
- **モデルが横倒し（Z-up のまま）に見える場合**: web-ifc の Y-up 変換がバージョンにより無効の可能性 → `ViewerViewController.loadView` の `modelRoot` に `modelRoot.orientation = simd_quatf(angle: -.pi/2, axis: [1,0,0])` を追加して補正し、このプランの該当行を正とする

- [ ] **Step 7: 全テストがまだ通ることを確認して commit**

```bash
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests test 2>&1 | tail -3
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add Shared App/Main.swift
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: RealityKitビューア（M2: 単体ビューアで3D表示・オービット操作）"
```

---

### Task 8: ModelLoader — プログレッシブストリーミング

**Files:**
- Create: `Shared/ModelLoader.swift`
- Modify: `Shared/ViewerViewController.swift`（`start(url:)` をプログレッシブ版に差し替え）

**Interfaces:**
- Consumes: `WebIFCBridge`, `MeshBatcher`, `LoadSummary`
- Produces: `ModelLoader.events(for:triangleLimit:flushInterval:) -> AsyncThrowingStream<LoadEvent, Error>`

- [ ] **Step 1: ModelLoader を書く**

`Shared/ModelLoader.swift`:

```swift
import Foundation

enum LoadEvent {
    case batches([MaterialBatch])   // 途中経過（プログレッシブ描画用）
    case finished(LoadSummary)      // 完了サマリ
}

/// バックグラウンドでパースし、一定間隔でバッチを flush する。
/// 「最初のバッチが揃った時点で描画開始」を実現する心臓部。
final class ModelLoader {
    func events(for url: URL,
                triangleLimit: Int = 20_000_000,
                flushInterval: Double = 0.25) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = ContinuousClock.now
                let batcher = MeshBatcher(triangleLimit: triangleLimit)
                var lastFlush = started
                do {
                    let info = try WebIFCBridge().streamMeshes(fromFileAtPath: url.path) { chunk in
                        batcher.add(chunk)
                        let now = ContinuousClock.now
                        if now - lastFlush > .milliseconds(Int(flushInterval * 1000)) {
                            let batches = batcher.drain()
                            if !batches.isEmpty { continuation.yield(.batches(batches)) }
                            lastFlush = now
                        }
                    }
                    let rest = batcher.drain()
                    if !rest.isEmpty { continuation.yield(.batches(rest)) }
                    let seconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
                    continuation.yield(.finished(LoadSummary(
                        schema: info.schemaVersion,
                        elementCount: Int(info.elementCount),
                        triangleCount: batcher.totalTriangles,
                        skippedElements: batcher.skippedElements,
                        seconds: seconds,
                        bounds: batcher.bounds)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

- [ ] **Step 2: ViewerViewController.start(url:) を差し替え**

`Shared/ViewerViewController.swift` の `start(url:)` を以下に置換（仮の一括版を削除）:

```swift
    /// ロード開始（プログレッシブ: バッチが届くたびに描画へ追加）
    func start(url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var framedOnce = false
            do {
                for try await event in ModelLoader().events(for: url) {
                    switch event {
                    case .batches(let batches):
                        self.append(batches: batches)
                        // 最初のバッチで即フレーミング（初回描画1秒以内の体感を作る）
                        if !framedOnce, let bounds = self.currentBounds(batches) {
                            self.cameraController.frame(bounds)
                            self.cameraController.apply(to: self.cameraEntity)
                            framedOnce = true
                        }
                    case .finished(let summary):
                        self.finish(summary: summary)
                    }
                }
            } catch {
                self.show(message: error.localizedDescription)
            }
        }
    }

    /// 初回フレーミング用: 受信済みバッチから暫定 AABB を計算
    private func currentBounds(_ batches: [MaterialBatch]) -> AABB? {
        var bounds: AABB?
        for batch in batches {
            var v = 0
            while v < batch.vertices.count {
                let p = SIMD3<Float>(batch.vertices[v], batch.vertices[v+1], batch.vertices[v+2])
                if bounds == nil { bounds = AABB(min: p, max: p) } else { bounds!.union(p) }
                v += 6
            }
        }
        return bounds
    }
```

※ `cameraController` と `cameraEntity` は private のままアクセスできるよう同一ファイル内に置く（既にそうなっている）。

- [ ] **Step 3: ビルド + 単体ビューアで目視確認 + テスト**

```bash
xcodegen generate
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests test 2>&1 | tail -3
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -derivedDataPath build/dd build 2>&1 | tail -3
open build/dd/Build/Products/Debug/IFCQuickLook.app
```

期待: fixture ではバッチが小さいので一瞬で表示（挙動が Task 7 と同等なら OK）。`** TEST SUCCEEDED **`。

- [ ] **Step 4: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add Shared/ModelLoader.swift Shared/ViewerViewController.swift
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: ModelLoaderによるプログレッシブストリーミング表示"
```

---

### Task 9: Quick Look 拡張 + UTI 宣言（M3 完了点）

**Files:**
- Modify: `PreviewExtension/PreviewViewController.swift`（stub を置換）
- Modify: `project.yml`（appex の NSExtension 定義・App の UTI 宣言を追記）

**Interfaces:**
- Consumes: `ViewerViewController`
- Produces: スペースキーで `.ifc` が 3D プレビューされる `IFCPreview.appex`

- [ ] **Step 1: PreviewViewController を実装**

`PreviewExtension/PreviewViewController.swift`:

```swift
// Quick Look プレビュー拡張のエントリポイント。
// ViewerViewController を埋め込み、ロードはプログレッシブに進むため
// preparePreview はビューを構築したら即座に完了を返す。
import AppKit
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let viewer = ViewerViewController()

    override func loadView() {
        view = NSView()
        addChild(viewer)
        viewer.view.frame = view.bounds
        viewer.view.autoresizingMask = [.width, .height]
        view.addSubview(viewer.view)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        viewer.start(url: url)
        // エラーはビュー内のエラービューで表示する（Fail Fast だが QL 自体は開く。
        // throw すると QL が汎用アイコンに差し替えてしまい理由が伝わらないため）。
    }
}
```

- [ ] **Step 2: project.yml に NSExtension と UTI 宣言を追記**

`project.yml` の `IFCPreview` の `info.properties` を以下に置換:

```yaml
    info:
      path: PreviewExtension/PreviewExtension-Info.plist
      properties:
        CFBundleDisplayName: IFC Preview
        NSExtension:
          NSExtensionPointIdentifier: com.apple.quicklook.preview
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).PreviewViewController
          NSExtensionAttributes:
            QLSupportedContentTypes:
              - org.buildingsmart.ifc
            QLSupportsSearchableItems: false
```

`IFCQuickLook`（App）の `info.properties` を以下に置換（UTI の importer 宣言 + 関連付け）:

```yaml
    info:
      path: App/App-Info.plist
      properties:
        NSPrincipalClass: NSApplication
        CFBundleDocumentTypes:
          - CFBundleTypeName: IFC Building Model
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [org.buildingsmart.ifc]
        UTImportedTypeDeclarations:
          - UTTypeIdentifier: org.buildingsmart.ifc
            UTTypeDescription: IFC Building Model
            UTTypeConformsTo: [public.data]
            UTTypeTagSpecification:
              public.filename-extension: [ifc]
```

- [ ] **Step 3: ビルドして QL に登録・実機確認**

```bash
xcodegen generate
xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -derivedDataPath build/dd build 2>&1 | tail -3
# LaunchServices / pluginkit に確実に載せるため /Applications に置く
rm -rf /Applications/IFCQuickLook.app
cp -R build/dd/Build/Products/Debug/IFCQuickLook.app /Applications/
open /Applications/IFCQuickLook.app   # 一度起動して登録を促す
sleep 2
pluginkit -m -p com.apple.quicklook.preview | grep -i ifc || echo "未登録"
qlmanage -r >/dev/null 2>&1
qlmanage -p Tests/Fixtures/minimal_wall.ifc
```

期待:
- `pluginkit` の出力に `jp.trapple.IFCQuickLook.IFCPreview` が現れる（`未登録` の場合はシステム設定 > 一般 > ログイン項目と機能拡張 > Quick Look で有効化してから再確認）
- `qlmanage -p` のウィンドウに壁の 3D が表示され、マウス操作が効く
- Finder で fixture を選んでスペースキーでも同様に表示される

- [ ] **Step 4: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add project.yml PreviewExtension/PreviewViewController.swift
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "feat: Quick Lookプレビュー拡張とUTI宣言（M3: スペースキーで3D表示）"
```

---

### Task 10: エラーハンドリングの仕上げ（M4 完了点）

**Files:**
- Create: `Tests/Fixtures/unsupported_schema.ifc`
- Test: `Tests/WebIFCBridgeTests.swift`（ケース追加）

**Interfaces:**
- Consumes: `WebIFCBridge` のエラー定数（Task 4）

- [ ] **Step 1: 非対応スキーマ fixture と失敗するテストを追加**

`Tests/Fixtures/unsupported_schema.ifc`:

```
ISO-10303-21;
HEADER;
FILE_DESCRIPTION((''),'2;1');
FILE_NAME('unsupported_schema.ifc','2026-07-12T00:00:00',(''),(''),'','','');
FILE_SCHEMA(('IFC2X2'));
ENDSEC;
DATA;
ENDSEC;
END-ISO-10303-21;
```

`Tests/WebIFCBridgeTests.swift` に追加:

```swift
    /// 非対応スキーマ → unsupportedSchema エラーで、メッセージにスキーマ名が入る
    func testUnsupportedSchemaThrows() {
        let bridge = WebIFCBridge()
        XCTAssertThrowsError(try bridge.streamMeshes(fromFileAtPath: fixtureURL("unsupported_schema").path) { _ in }) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, IFCBridgeErrorDomain)
            XCTAssertEqual(ns.code, IFCBridgeError.unsupportedSchema.rawValue)
            XCTAssertTrue(ns.localizedDescription.contains("IFC2X2"))
        }
    }
```

- [ ] **Step 2: 実行して結果を確認**

実行: `xcodegen generate && xcodebuild -project IFCQuickLook.xcodeproj -scheme IFCQuickLook -only-testing:IFCCoreTests test 2>&1 | tail -5`
期待: Task 4 の実装で既に通るはず → PASS。通らなければ WebIFCBridge.mm のスキーマ判定を修正して PASS させる。

- [ ] **Step 3: QL 上でエラー表示を目視確認**

```bash
qlmanage -p Tests/Fixtures/broken.ifc
qlmanage -p Tests/Fixtures/unsupported_schema.ifc
```

期待: 空画面ではなく「IFC ヘッダ（FILE_SCHEMA）が見つかりません…」「非対応スキーマです: IFC2X2…」がそれぞれ中央に表示される。

- [ ] **Step 4: commit**

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add Tests
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "test: 非対応スキーマ・壊れファイルのエラー表示を検証（M4）"
```

---

### Task 11: 実データでの性能計測とチューニング（M5 完了点）

**Files:**
- Modify: `README.md`（性能計測結果の表を追記）

**Interfaces:**
- Consumes: `ifcql-bench`（Task 6）

- [ ] **Step 1: 公開サンプル IFC を取得（中規模→大規模の順に検証）**

```bash
mkdir -p build/samples
# buildingSMART 公式サンプル（中規模）。URL 失効時は https://github.com/buildingSMART/Sample-Test-Files で代替を探す
curl -L --max-time 120 -o build/samples/schependomlaan.ifc \
  "https://raw.githubusercontent.com/buildingSMART/Sample-Test-Files/master/IFC%202x3/Schependomlaan/Design%20model%20IFC/IFC%20Schependomlaan.ifc"
ls -lh build/samples/
```

期待: 数十MB のファイルが取得できる。手元に実務の数百MB級 IFC があればそれも `build/samples/` に置く（git 管理外）。

- [ ] **Step 2: ベンチ実行と QL 体感確認**

```bash
./build/dd/Build/Products/Debug/ifcql-bench build/samples/schependomlaan.ifc
qlmanage -p build/samples/schependomlaan.ifc
```

期待（spec の受け入れ基準）:
- 中規模（数十MB）: `parse_s` が 1 桁秒
- QL 表示: 最初のジオメトリが**1秒以内**に現れ、その後プログレッシブに増える
- 操作中 60fps 近辺（体感でカクつかない）
- `peak_mem_mb` がファイルサイズの 5 倍を大きく超えない

- [ ] **Step 3: 基準未達の場合のチューニング候補（計測してから着手。推測で最適化しない）**

計測で律速を特定してから、上から順に効果の大きいものを適用する:

1. `flushInterval` の調整（0.25s → 最初の 1 回だけ 0.1s にする等、初回体感を優先）
2. `MeshBatcher.add` の AABB 計算を SIMD 化 / 頂点コピーを `memcpy` 化
3. `MeshDescriptor` 生成を `LowLevelMesh`（macOS 15+）に置換してコピーを削減
4. web-ifc の `circleSegments` を 12 → 8 に下げてテッセレーション削減
5. ModelLoader の flush 粒度を「三角形数ベース」（例: 50 万三角形ごと）に変更

- [ ] **Step 4: 結果を README に記録して commit**

`README.md` に追記:

```markdown
## 性能計測（ifcql-bench）

| ファイル | サイズ | parse_s | triangles | peak_mem_mb | 計測日 |
|---|---|---|---|---|---|
| （実測値で埋める） | | | | | 2026-07-12 |
```

```bash
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook add README.md
git -C /Users/trapple/repos/github.com/trapple/ifc-quicklook commit -m "perf: 実データでの性能計測結果を記録（M5）"
```

---

## セルフレビュー記録

- **spec カバー率:** プレビュー拡張のみ(Task 9) / 3Dインタラクティブ(Task 7) / 数百MB対応・プログレッシブ(Task 8, 11) / mmap(Task 4) / 三角形上限+省略表示(Task 5, 7) / Fail Fast エラービュー(Task 4, 7, 10) / CLI ベンチ(Task 6) / 単体ビューア(Task 7) / UTI 宣言(Task 9) — 全セクション対応あり。notarize は spec でスコープ外扱いのため対象外
- **型一貫性:** `IFCMeshChunk`/`IFCModelInfo`/`MaterialBatch`/`AABB`/`LoadSummary`/`LoadEvent` の定義箇所と全使用箇所を突き合わせ済み。`LoadSummary` は Task 7 で定義し Task 8 が消費
- **外部 API リスク:** web-ifc のネイティブ API はバージョン差があるため、Task 3 の smoke テストで実シグネチャを確定させ「test_load.cpp を正とする」ルールで Task 4 に伝播させる設計にした（placeholder ではなく検証手順として明記）
- **PJ 規約整合:** コメント日本語 / `git -C` / timeout 意識（ビルド10分・curl 120s）/ 小さい fixture から検証、いずれも反映済み
