# IFC Quick Look

[English](README.md) | 日本語

.ifc（BIM / IFC）ファイルを Finder のスペースキーでプレビューする macOS Quick Look 拡張。
[web-ifc](https://github.com/ThatOpen/engine_web-ifc)（ネイティブ静的ライブラリ化）+ RealityKit によるネイティブ実装（WebView なし・中間ファイル変換なし）。

- ドラッグで回転、ピンチ / 2本指スクロールでズーム、Shift+ドラッグでパン
- プログレッシブ表示: 1秒以内に描画が始まり、パースの進行に合わせて建物が生えていく
- 対応: IFC2x3 / IFC4 / IFC4x3、macOS 15+（Apple Silicon）
- 壊れたファイル・非対応スキーマは理由を明示するエラー表示

## インストール (Homebrew)

```bash
brew install trapple/tap/ifc-quicklook
open /Applications/IFCQuickLook.app   # 初回のみ: Quick Look 拡張の登録
```

既存の .ifc がプレビューされない場合（インストール前にインデックスされたファイル）は再インポート:

```bash
mdimport <ifcファイルのあるフォルダ>
```

## 性能

`ifcql-bench`（Release, Apple Silicon）での実測:

| ファイル | サイズ | パース | 三角形 | ピークメモリ |
|---|---|---|---|---|
| schependomlaan.ifc (IFC2X3) | 47 MB | 0.5 s | 262,589 | 211 MB |
| S_Office (IFC2X3) | 30 MB | 2.3 s | 1,169,931 | 361 MB |
| ISSUE_098 (IFC2X3) | 70 MB | 6.3 s | 1,645,196 | 611 MB |

## 巨大ファイルの扱い

Quick Look 拡張プロセスには OS 側の制約があり、メモリ footprint 約 1GB を超えると圧縮スワップで数倍遅くなる。スペースキーの即応性を守るため、プレビューは**パース3秒 or 800MB で打ち切り**、そこまでの内容を表示して「⚠︎ N要素を省略」と明示する。

全体を見たいときは同梱ビューアアプリで開く（無制限。122MB・280万三角形の実測で約18秒）:

Finder → 右クリック → このアプリケーションで開く → IFCQuickLook

## ソースからビルド

要件: macOS 15+（Apple Silicon）/ Xcode / cmake / xcodegen（`brew install cmake xcodegen`）

```bash
make install   # submodule取得 → web-ifcビルド → xcodegen → xcodebuild → /Applications に配置 → 拡張登録
```

プレビューが出ないときは `make reset`（qlmanage キャッシュリセット）と `killall Finder`。
それでも出ないときは `pluginkit -m | grep IFCPreview` で登録を確認する。

### 開発ビルドと本番の競合に注意

DerivedData 等の appex が pluginkit に登録されると QL がどちらを使うか不定になる。
`lsregister -u <開発ビルドのapp>` で解除して /Applications 版だけにする。

## 開発

```bash
make test      # ユニットテスト
make ql        # qlmanage -p で同梱fixtureを直接プレビュー
```

設計ドキュメント: `.claude/specs/2026-07-12-ifc-quicklook-design.md`

## ライセンス

本体は [MIT](LICENSE)。配布バイナリには [web-ifc](https://github.com/ThatOpen/engine_web-ifc)（MPL-2.0）のコンパイル済みコードが含まれる。web-ifc のソースは上流リポジトリおよび本リポジトリの submodule（`vendor/web-ifc`、タグ固定）から入手できる。
