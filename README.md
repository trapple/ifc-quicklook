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
