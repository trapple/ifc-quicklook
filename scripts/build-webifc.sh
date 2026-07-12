#!/bin/bash
# web-ifc をネイティブ静的ライブラリとしてビルドし、.webifc/{lib,include} に集約する。
# 冪等: 再実行すると作り直す。
# upstream 構成 (0.77): CMake プロジェクトルートは src/cpp、
# 非 Emscripten 時に静的ライブラリターゲット `web-ifc-library` が定義される。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/web-ifc/src/cpp"
BUILD="$ROOT/build/webifc"
OUT="$ROOT/.webifc"

# upstream の CMake でネイティブビルド（Emscripten なし）
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$BUILD" --target web-ifc-library --parallel "$(sysctl -n hw.ncpu)"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"

# 生成された静的ライブラリを 1 本に統合（依存はヘッダオンリーのため通常 1 本）
LIBS=$(find "$BUILD" -name '*.a')
echo "統合対象: $LIBS"
libtool -static -o "$OUT/lib/libweb-ifc.a" $LIBS

# ヘッダ集約: web-ifc 本体（include は "web-ifc/parsing/IfcLoader.h" 形式）
rsync -a --include='*/' --include='*.h' --include='*.hpp' --exclude='*' \
  "$SRC/web-ifc/" "$OUT/include/web-ifc/"

# ヘッダ集約: FetchContent で落ちた依存
# 公開ヘッダが必要とするのは glm のみだが、他もコンパイル時に備えて集約しておく
rsync -a "$BUILD/_deps/glm-src/glm" "$OUT/include/"                 # <glm/glm.hpp>
rsync -a "$BUILD/_deps/tinynurbs-src/include/" "$OUT/include/"      # <tinynurbs/tinynurbs.h>
rsync -a "$BUILD/_deps/fastfloat-src/include/" "$OUT/include/"      # <fast_float/...>
rsync -a "$BUILD/_deps/cdt-src/CDT/include/" "$OUT/include/"        # <CDT.h>
rsync -a "$BUILD/_deps/earcut-src/include/" "$OUT/include/"         # <mapbox/earcut.hpp>
rsync -a "$BUILD/_deps/spdlog-src/include/" "$OUT/include/"         # <spdlog/...>
rsync -a "$BUILD/_deps/stduuid-src/include/" "$OUT/include/"        # <uuid.h>

echo "OK: $OUT/lib/libweb-ifc.a"
lipo -info "$OUT/lib/libweb-ifc.a" || true
