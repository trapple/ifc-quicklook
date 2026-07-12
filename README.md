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

## 性能計測（ifcql-bench, Release, Apple Silicon）

| ファイル | サイズ | parse_s | triangles | peak_mem_mb | 計測日 |
|---|---|---|---|---|---|
| schependomlaan.ifc (IFC2X3) | 47MB | 0.48 | 262,589 | 211 | 2026-07-12 |
| S_Office_Integrated Design Archi.ifc (IFC2X3) | 30MB | 2.33 | 1,169,931 | 361 | 2026-07-12 |
| ISSUE_098_R8_F1_MAB_AR_M3_XX_XXX_MO_7000.ifc (IFC2X3) | 70MB | 6.32 | 1,645,196 | 611 | 2026-07-12 |

- Quick Look 実測: schependomlaan (47MB) はスペースキーから約 0.6 秒でフル表示
- 計測ファイルは `vendor/web-ifc/tests/ifcfiles/public/` に同梱のものを使用

## Quick Look の制約と設計判断

QL 拡張プロセスには OS 側の制約があり（変更不可）、以下の設計で対応している:

| 制約 | 対応 |
|---|---|
| メモリ footprint 約1GB から圧縮スワップで数倍遅くなる | web-ifc のジオメトリキャッシュを32要素ごとに解放・トークンテープ256MB制限・**800MB 到達で残り要素を省略**（⚠表示） |
| ちら見用途では待たせられない | **パース3秒デッドライン**で打ち切り（⚠表示）。QLは必ず数秒で応答する |
| プロセスが使い回され複数プレビューが並走 | パースをプロセス内で直列化（web-ifc は非スレッドセーフ）・プレビュー終了時にメッシュ即解放 |
| GCDワーカースレッドのスタック512KBでは `GetMesh()` の深い再帰が溢れる | 32MBスタックの専用スレッドでパース |

**巨大ファイルの全体表示は同梱アプリで**: Finder で右クリック → このアプリケーションで開く → IFCQuickLook（メモリ・時間無制限。122MB/279万三角形の実測で18秒）。

## トラブルシューティング

- **スペースキーで反応しない（汎用アイコンのまま）**: アプリのUTI宣言より前に Spotlight にインデックスされたファイルは動的UTIのまま。`mdimport <file or folder>` で再インポートすると直る
- **拡張が登録されない**: `pluginkit -a /Applications/IFCQuickLook.app/Contents/PlugIns/IFCPreview.appex` で明示登録 → `qlmanage -r`
- **開発ビルドと本番が競合して不安定**: DerivedData 等の appex が pluginkit に登録されると QL がどれを使うか不定になる。`lsregister -u <dev-app-path>` で解除して /Applications 版だけにする
