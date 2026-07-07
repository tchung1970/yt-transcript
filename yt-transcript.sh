#!/usr/bin/env bash
#
# yt-transcript.sh — get a transcript for a YouTube video.
#
# Strategy:
#   1. Try to download existing captions (manual, then auto-generated) with yt-dlp.
#   2. If none exist, download the audio and transcribe it locally with whisper.
#
# Output: a plain-text "ytt_<date>_<time>.txt" in the output directory (default: current dir).
#
# Usage:
#   ./yt-transcript.sh <youtube-url-or-id> [-o output_dir] [-l lang] [-m whisper_model] [-k]
#
#   -o  output directory            (default: current directory)
#   -l  caption language            (default: en)
#   -m  whisper model for fallback  (default: small)
#   -k  keep intermediate files (vtt/audio) instead of deleting them

set -euo pipefail

OUT_DIR="."
SUB_LANG="en"
WHISPER_MODEL="small"
KEEP=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# --- parse args ---
URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT_DIR="$2"; shift 2 ;;
    -l) SUB_LANG="$2"; shift 2 ;;
    -m) WHISPER_MODEL="$2"; shift 2 ;;
    -k) KEEP=1; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)  URL="$1"; shift ;;
  esac
done

[[ -z "$URL" ]] && usage

command -v yt-dlp >/dev/null || { echo "Error: yt-dlp not found." >&2; exit 1; }

mkdir -p "$OUT_DIR"

# Fetch metadata in one call; one field per line, in a fixed order.
# Pre-declare so `set -u` is happy if any field is missing, and guard the whole
# block with `|| true`: a short/empty read (blocked network, empty field, no
# trailing newline) makes `read` return non-zero, which under `set -e` would
# otherwise abort the script *silently* before we ever try the caption download.
TITLE="" DURATION_S="" CHANNEL="" UPLOADED="" VIEWS=""
{ read -r TITLE; read -r DURATION_S; read -r CHANNEL; read -r UPLOADED; read -r VIEWS; } < <(
  yt-dlp --no-warnings --skip-download \
    --print "%(title)s" --print "%(duration)s" --print "%(channel)s" \
    --print "%(upload_date>%Y-%m-%d)s" --print "%(view_count)s" \
    "$URL" 2>/dev/null
) || true

# fmt_duration <seconds> -> "1h 2m 3s" (omits leading zero units).
fmt_duration() {
  local s="${1:-0}" out=""
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "?"; return; }
  (( s >= 3600 )) && out+="$(( s / 3600 ))h "
  (( s >= 60 ))   && out+="$(( s % 3600 / 60 ))m "
  out+="$(( s % 60 ))s"
  echo "$out"
}
DURATION="$(fmt_duration "$DURATION_S")"

OUT_TXT="$OUT_DIR/ytt_$(date +%Y%m%d_%H%M%S).txt"

echo ">> Title   : ${TITLE:-?}"
echo "   Channel : ${CHANNEL:-?}"
echo "   Length  : ${DURATION:-?}"
echo "   Uploaded: ${UPLOADED:-?}"
echo "   Views   : ${VIEWS:-?}"

# Sentences per paragraph in the reflowed output.
PARA_SENTENCES=4

# vtt_to_text <vtt_file>: strip WEBVTT header, timestamps, and tags, then reflow
# the short caption lines into readable paragraphs (blank line every N sentences).
vtt_to_text() {
  sed -e '/-->/d' -e '/^WEBVTT/d' -e '/^Kind:/d' -e '/^Language:/d' \
      -e 's/<[^>]*>//g' -e 's/\r$//' -e '/^[[:space:]]*$/d' "$1" \
    | awk -v per="$PARA_SENTENCES" '
        $0 != prev { text = text $0 " "; prev = $0 }
        END {
          gsub(/  +/, " ", text)
          gsub(/[.!?]+["'\'')]* +/, "&\001", text)   # mark end of each sentence
          n = split(text, s, "\001")
          para = ""; c = 0
          for (i = 1; i <= n; i++) {
            gsub(/^ +| +$/, "", s[i])
            if (s[i] == "") continue
            para = para (para ? " " : "") s[i]
            if (++c >= per) { print para "\n"; para = ""; c = 0 }
          }
          if (para != "") print para
        }'
}

TMP_DIR="$(mktemp -d)"
cleanup() { [[ "$KEEP" -eq 0 ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# --- 1. Try existing captions (manual first, then auto-generated) ---
echo ">> Checking for captions ($SUB_LANG)..."
if yt-dlp --quiet --no-warnings --skip-download \
      --write-sub --write-auto-sub --sub-lang "$SUB_LANG" --sub-format vtt \
      -o "$TMP_DIR/%(id)s.%(ext)s" "$URL" >/dev/null 2>&1; then
  VTT="$(find "$TMP_DIR" -name '*.vtt' | head -n1 || true)"
  if [[ -n "$VTT" ]]; then
    echo ">> Found captions — converting to text."
    vtt_to_text "$VTT" > "$OUT_TXT"
    [[ "$KEEP" -eq 1 ]] && cp "$VTT" "$OUT_DIR/"
    echo ">> Saved: $OUT_TXT"
    exit 0
  fi
fi

# --- 2. Fallback: download audio and transcribe with whisper ---
echo ">> No captions found — transcribing audio with whisper ($WHISPER_MODEL)."
command -v whisper >/dev/null || { echo "Error: whisper not found (needed for fallback)." >&2; exit 1; }

AUDIO="$TMP_DIR/audio.m4a"
if ! yt-dlp --quiet --no-warnings -f 'bestaudio' -x --audio-format m4a -o "$AUDIO" "$URL" >/dev/null 2>&1 \
     || [[ ! -s "$AUDIO" ]]; then
  echo "Error: could not download audio for transcription (network blocked or no audio stream)." >&2
  exit 1
fi

whisper "$AUDIO" --model "$WHISPER_MODEL" --output_format txt --output_dir "$TMP_DIR" >/dev/null 2>&1 || true
WTXT="$(find "$TMP_DIR" -name '*.txt' | head -n1 || true)"
if [[ -z "$WTXT" || ! -s "$WTXT" ]]; then
  echo "Error: whisper produced no transcript." >&2
  exit 1
fi
cp "$WTXT" "$OUT_TXT"
[[ "$KEEP" -eq 1 ]] && cp "$AUDIO" "$OUT_DIR/"

echo ">> Saved: $OUT_TXT"
