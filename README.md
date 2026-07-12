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
