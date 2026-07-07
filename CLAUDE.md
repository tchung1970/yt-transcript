# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Single Bash script (`yt-transcript.sh`) that gets a transcript for a YouTube video: it downloads existing captions if the video has them, otherwise falls back to transcribing the audio locally with whisper. Output is a plain-text file in the current directory (override with `-o`) named by timestamp, `ytt_YYYYMMDD_HHMMSS.txt` (e.g. `ytt_20260706_212133.txt`). The video title is printed to the console but not used in the filename.

Installed as `~/bin/ytt` (symlink). Since YouTube URLs contain `?` and `&`, `~/.zshrc` aliases `ytt` to `noglob ytt` so URLs can be passed unquoted.

## Usage

```bash
./yt-transcript.sh <youtube-url-or-id> [-o output_dir] [-l lang] [-m whisper_model] [-k]
```

- `-o` output directory (default: current directory)
- `-l` caption language (default `en`)
- `-m` whisper model for the fallback path (default `small`)
- `-k` keep intermediate files (`.vtt`, audio) instead of deleting them

## Architecture

The script is a thin orchestrator over external CLI tools — there is no library code and no package to install. On start it prints video metadata (title, channel, length, upload date, views) fetched in a single `yt-dlp --skip-download --print ...` call using one `--print` flag per field (this yt-dlp does not expand `\t` inside a template, so fields are read one-per-line rather than tab-split). The two-stage flow is the whole design:

1. **Caption path (preferred):** `yt-dlp --write-sub --write-auto-sub` fetches manual or auto-generated captions as VTT into a temp dir. The `vtt_to_text` shell function strips the WEBVTT header, timestamp cue lines (`-->`), inline tags, and consecutive duplicate lines (common in rolling auto-captions), then **reflows** the short caption-width lines into readable paragraphs: an `awk` block reassembles the words into continuous text, splits it into sentences (on `.!?` boundaries), and emits a blank line every `PARA_SENTENCES` sentences (default 4) so the output reads as prose rather than ragged ~40-char subtitle lines. All newline insertion is done in `awk`, not `sed`, because macOS/BSD `sed` does not expand `\n` in a replacement. If a VTT is found, the script writes the text and exits before the fallback.
2. **Transcription fallback:** only runs when no captions exist. `yt-dlp -x --audio-format m4a` extracts audio, then the `whisper` CLI transcribes it to text. The whisper output is copied as-is and does **not** go through the paragraph reflow (only the caption path does).

See `README.md` for full user-facing documentation (install, options, examples).

Intermediate work happens in a `mktemp -d` directory removed by an `EXIT` trap (unless `-k` is passed).

## External dependencies (must be on PATH)

- `yt-dlp` — captions + audio download (required)
- `whisper` (openai-whisper CLI) — only needed for the fallback path
- `ffmpeg` — used by yt-dlp for audio extraction

On this machine `whisper` is installed under Python 3.12's framework bin, separate from the default `python3` (3.14). The script invokes the `whisper` binary directly, so this split doesn't matter — but note that `pip install`-ing whisper for the default interpreter will not put it where the script expects unless it lands on PATH.

## Notes for making changes

- `set -euo pipefail` is on; guard optional command substitutions with `|| true` (as the `find` calls already do) so an empty result doesn't abort the script. In particular the metadata `read` block is guarded with `|| true`: `read` returns non-zero on a short/empty stream (blocked network, empty field, missing trailing newline), which under `set -e` would otherwise abort the script *silently* before the caption download ever runs. The whisper fallback download/transcribe steps are likewise guarded and emit an explicit `Error:` to stderr with a non-zero exit rather than dying silently — this matters when the script runs as a packaged skill, where a silent exit reads as "did nothing".
- The caption-track variable is `SUB_LANG`, **not** `LANG` — `LANG` is the locale environment variable and clobbering it can change awk/yt-dlp/whisper behavior.
- The output filename is a `date +%Y%m%d_%H%M%S` timestamp, so back-to-back runs within the same second would collide; in practice this never happens given download latency.
- yt-dlp and whisper are run fully silenced (`--quiet ... >/dev/null 2>&1`); only the script's own `>>` status lines reach the console. When debugging a download failure, temporarily remove those redirects to see the tool output.
- Test the caption path with `jNQXAC9IVRw` (has captions). To exercise the whisper fallback, use a video with captions disabled — it is slow and model-download-heavy on first run.

## Skill packaging

`yt-transcript-skill.zip` is the packaged Claude skill. It contains `yt-transcript/yt-transcript.sh` (a byte-for-byte copy of the script in this directory) plus `yt-transcript/SKILL.md`; it does **not** include `CLAUDE.md`, `README.md`, or the sample `ytt_*.txt` output. The zip's copy of the script does **not** update automatically — after editing `yt-transcript.sh` you must re-package the zip (and keep `SKILL.md` in sync). To confirm the loose script and the zipped one match, compare their checksums (`shasum yt-transcript.sh` vs the extracted copy).
