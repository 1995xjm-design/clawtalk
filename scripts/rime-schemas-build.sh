#!/usr/bin/env bash
# encoding: utf-8
# ClawTalk 咕噜极简九宫格：Rime 简体拼音方案生成脚本（macOS CI 用）
# 由 GuruIM-zh InputSchemaBuild.sh 精简：只保留 朙月拼音·简化字 + prelude + essay + opencc
# 产物：ClawTalkKeyboard/Resources/SharedSupport/SharedSupport.zip（条目在根下，无顶层文件夹）
set -ex

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ClawTalkKeyboard/Resources/SharedSupport"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DST="$TMP/SharedSupport"
mkdir -p "$DST/opencc"

# 1) prelude 基础文件
echo "[rime] clone prelude"; git clone --depth 1 https://github.com/rime/rime-prelude.git "$TMP/prelude"
cp "$TMP"/prelude/{default.yaml,key_bindings.yaml,punctuation.yaml,symbols.yaml} "$DST/"

# 2) 朙月拼音方案
echo "[rime] clone luna-pinyin"; git clone --depth 1 https://github.com/rime/rime-luna-pinyin.git "$TMP/luna"
cp "$TMP"/luna/{luna_pinyin.schema.yaml,luna_pinyin_simp.schema.yaml,luna_pinyin_fluency.schema.yaml,luna_pinyin_tw.schema.yaml,luna_quanpin.schema.yaml,luna_pinyin.dict.yaml,pinyin.yaml} "$DST/"

# 3) 词频表
echo "[rime] clone essay"; git clone --depth 1 https://github.com/rime/rime-essay.git "$TMP/essay"
cp "$TMP/essay/essay.txt" "$DST/"

# 4) opencc 数据（librime 1.8.5 发布包 share/opencc）
echo "[rime] download deps"; curl -fL -o "$TMP/rime-deps.tar.bz2" https://github.com/rime/librime/releases/download/1.8.5/rime-deps-08dd95f-macOS.tar.bz2
tar -xf "$TMP/rime-deps.tar.bz2" -C "$TMP"
cp -R "$TMP/share/opencc/"* "$DST/opencc/"

# 5) 键盘配置（九宫格默认）
cp "$OUT/hamster.yaml" "$DST/"

# 6) default.yaml: leave schema_list empty (same as Hamster), so that the
#    rime-ice default.yaml deployed in UserData takes over the schema list.
python3 - "$DST/default.yaml" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
start = s.index("schema_list:")
end = s.index("\nswitcher:", start)
s = s[:start] + "schema_list:\n\n" + s[end:]
open(path, "w", encoding="utf-8").write(s)
PY

# 7) rime-ice (includes the t9 Chinese nine-key schema): rime-ice.zip is a
#    committed resource (same snapshot as Hamster). Regenerate only if missing.
if [ ! -f "$OUT/rime-ice.zip" ]; then
  echo "[rime] rime-ice.zip missing, cloning rime-ice"
  git clone --depth 1 https://github.com/iDvel/rime-ice.git "$TMP/rime-ice"
  mkdir -p "$OUT"
  ( cd "$TMP/rime-ice" && zip -qr "$OUT/rime-ice.zip" . -x ".git/*" )
else
  echo "[rime] rime-ice.zip exists, reuse committed resource"
fi
ls -lh "$OUT/rime-ice.zip"
echo "done: $OUT/rime-ice.zip"
ls -lh "$OUT/rime-ice.zip"

# 8) package SharedSupport.zip (entries at root, no top-level folder)
mkdir -p "$OUT"
( cd "$DST" && zip -qr "$OUT/SharedSupport.zip" . )
echo "done: $OUT/SharedSupport.zip"
ls -lh "$OUT/SharedSupport.zip"
