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

## 「読み込み中…」のまま固まったら

v1.0.1 でハング対策を入れた（読み込みの各段階にデッドライン、ハング検知時はエラー表示してプレビューを閉じた時点でプロセスを自動再作成）。それでも固まる場合は、固まった状態のままターミナルで以下を実行して、出力を添えて [Issue](https://github.com/trapple/ifc-quicklook/issues) で報告してほしい:

```bash
IFC="ここに固まった.ifcファイルのパスを入れる"
{
  sw_vers
  sysctl -n machdep.cpu.brand_string
  echo "RAM: $(($(sysctl -n hw.memsize)/1073741824)) GB"
  mdls -name kMDItemFSSize "$IFC"
  PID=$(pgrep -x IFCPreview | tail -1)
  echo "IFCPreview PID: ${PID:-見つからない}"
  [ -n "$PID" ] && sample "$PID" 5 -file /tmp/ifcql_sample.txt >/dev/null 2>&1 \
    && { grep -A 35 "ModelLoader" /tmp/ifcql_sample.txt \
         || grep -m1 -A 40 "Call graph" /tmp/ifcql_sample.txt; }
} 2>&1
```

パースは `jp.trapple.IFCQuickLook.ModelLoader` という名前の専用スレッドで動いているので、そのスタックからどこで止まっているか（パース内部か、前のプレビューの待ち＝`semaphore_wait` か）を特定できる。

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
