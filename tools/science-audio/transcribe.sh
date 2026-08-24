#!/usr/bin/env bash
# transcribe.sh — 为下载到的音频生成同步 SRT/VTT
# 用法:
#   ./transcribe.sh                # 转写 $OUTPUT_ROOT 下全部音频
#   ./transcribe.sh ~/ScienceAudio/kids/SciShow_Kids
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

ROOT="${1:-$OUTPUT_ROOT}"
if [[ ! -d "$ROOT" ]]; then
  echo "目录不存在: $ROOT" >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd)"

PY_BIN="${PYTHON:-python3}"
MODEL="${MODEL:-small}"                       # tiny / base / small / medium / large-v3，或本地模型路径
LANGUAGE="${LANGUAGE:-en}"                    # 不确定语种可设 auto
# config.env 里叫 SKIP_EXISTING_SRT，早期脚本叫 SKIP_EXISTING，两个都认
SKIP_EXISTING="${SKIP_EXISTING_SRT:-${SKIP_EXISTING:-1}}"
KEEP_JSON="${KEEP_JSON:-0}"                   # 1=保留中间 whisper.json

need_cmd "$PY_BIN"

echo "目录: $ROOT"
echo "模型: $MODEL  语言: $LANGUAGE  解释器: $PY_BIN"

ENGINE=""
if "$PY_BIN" -c "import mlx_whisper" 2>/dev/null; then
  ENGINE="mlx"
  echo "引擎: mlx-whisper"
elif "$PY_BIN" -c "import faster_whisper" 2>/dev/null; then
  ENGINE="faster"
  echo "引擎: faster-whisper"
elif "$PY_BIN" -c "import whisper" 2>/dev/null; then
  ENGINE="openai"
  echo "引擎: openai-whisper"
else
  echo "请先安装其一:" >&2
  echo "  $PY_BIN -m pip install mlx-whisper      # Apple Silicon 最快" >&2
  echo "  $PY_BIN -m pip install faster-whisper" >&2
  echo "  $PY_BIN -m pip install openai-whisper" >&2
  exit 1
fi

run_engine() {
  local mp3="$1" json="$2"
  case "$ENGINE" in
    mlx)
      "$PY_BIN" - "$mp3" "$json" "$MODEL" "$LANGUAGE" <<'PY'
import sys, json
from pathlib import Path
import mlx_whisper

audio, out_json, model, lang = sys.argv[1:5]
model_map = {
    "tiny": "mlx-community/whisper-tiny-mlx",
    "base": "mlx-community/whisper-base-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
}
kwargs = {"path_or_hf_repo": model_map.get(model, model), "word_timestamps": False}
if lang and lang != "auto":
    kwargs["language"] = lang
result = mlx_whisper.transcribe(audio, **kwargs)
Path(out_json).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
print("    segments:", len(result.get("segments") or []))
PY
      ;;
    faster)
      "$PY_BIN" - "$mp3" "$json" "$MODEL" "$LANGUAGE" <<'PY'
import sys, json
from pathlib import Path
from faster_whisper import WhisperModel

audio, out_json, model_size, lang = sys.argv[1:5]
model = WhisperModel(model_size, device="auto", compute_type="int8")
segments, info = model.transcribe(audio, language=None if lang == "auto" else lang)
segs = [{"start": s.start, "end": s.end, "text": (s.text or "").strip()} for s in segments]
Path(out_json).write_text(
    json.dumps({"segments": segs, "language": getattr(info, "language", lang)}, ensure_ascii=False),
    encoding="utf-8",
)
print("    segments:", len(segs))
PY
      ;;
    *)
      "$PY_BIN" - "$mp3" "$json" "$MODEL" "$LANGUAGE" <<'PY'
import sys, json
from pathlib import Path
import whisper

audio, out_json, model_size, lang = sys.argv[1:5]
model = whisper.load_model(model_size)
result = model.transcribe(audio, language=None if lang == "auto" else lang)
Path(out_json).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
print("    segments:", len(result.get("segments") or []))
PY
      ;;
  esac
}

json_to_subs() {
  local json="$1" srt="$2" vtt="$3"
  "$PY_BIN" - "$json" "$srt" "$vtt" <<'PY'
import sys, json
from pathlib import Path


def stamp(seconds, sep):
    # 先四舍五入到整毫秒再拆，进位链一次算完，
    # 避免 ms/秒/分逐级进位时漏掉最高位（3599.9999 会变成 00:60:00）
    total_ms = max(0, int(round(float(seconds) * 1000)))
    h, rem = divmod(total_ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
segs = data.get("segments") or []

srt_lines, vtt_lines, idx = [], ["WEBVTT", ""], 0
for seg in segs:
    text = (seg.get("text") or "").strip()
    if not text:
        continue
    start = float(seg["start"])
    end = float(seg["end"])
    if end <= start:
        end = start + 0.5
    idx += 1
    srt_lines += [str(idx), f"{stamp(start, ',')} --> {stamp(end, ',')}", text, ""]
    vtt_lines += [f"{stamp(start, '.')} --> {stamp(end, '.')}", text, ""]

if idx == 0:
    print("    没有产出任何字幕行", file=sys.stderr)
    sys.exit(1)

Path(sys.argv[2]).write_text("\n".join(srt_lines) + "\n", encoding="utf-8")
Path(sys.argv[3]).write_text("\n".join(vtt_lines) + "\n", encoding="utf-8")
print(f"    cues={idx}")
PY
}

transcribe_one() {
  local audio="$1"
  local base="${audio%.*}"
  local srt="${base}.srt"
  local vtt="${base}.vtt"
  local json="${base}.whisper.json"

  if [[ "$SKIP_EXISTING" == "1" && -s "$srt" ]]; then
    echo "  skip: $(basename "$audio")"
    return 0
  fi

  echo "  转写: $(basename "$audio")"

  # 这个函数总是以 `transcribe_one ... || ...` 的形式调用，
  # 那种上下文里 set -e 在整个函数体内失效，所以每一步都要自己查返回值，
  # 否则转写失败会继续往下跑，去读一个根本不存在的 json
  if ! run_engine "$audio" "$json"; then
    echo "    转写引擎报错" >&2
    rm -f "$json"
    return 1
  fi

  if ! json_to_subs "$json" "$srt" "$vtt"; then
    echo "    生成字幕失败" >&2
    [[ "$KEEP_JSON" == "1" ]] || rm -f "$json"
    return 1
  fi

  [[ "$KEEP_JSON" == "1" ]] || rm -f "$json"
  return 0
}

# 扩展名跟着 AUDIO_FORMAT 走，另外把常见的几种都带上，
# 不然改了 AUDIO_FORMAT 就一个文件都找不到
declare -a find_expr=()
for ext in "${AUDIO_FORMAT:-mp3}" mp3 m4a opus flac wav ogg; do
  find_expr+=(-o -iname "*.${ext}")
done
find_expr=("${find_expr[@]:1}")   # 去掉最前面多余的 -o

# 只走一遍盘，结果留在数组里给后面复用
declare -a files=()
mapfile -t -d '' files < <(find "$ROOT" -type f \( "${find_expr[@]}" \) -print0 | sort -z)

total=${#files[@]}
echo "共 $total 个音频文件"
echo ""

if [[ $total -eq 0 ]]; then
  echo "没有可转写的文件。"
  exit 0
fi

done_n=0
fail_n=0
for f in "${files[@]}"; do
  if ! transcribe_one "$f"; then
    fail_n=$((fail_n + 1))
    echo "  FAIL: $f"
  fi
  done_n=$((done_n + 1))
  echo "  进度: $done_n / $total"
done

echo ""
echo "完成。SRT/VTT 与对应音频同目录、同主文件名。"
echo "处理: $done_n  失败: $fail_n"

[[ "$fail_n" -eq 0 ]] || exit 1
