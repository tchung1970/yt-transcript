# yt-transcript

Get a clean, human-readable transcript for any YouTube video from the command line.

Given a URL (or bare video ID), the script downloads the video's existing captions
if it has them, and otherwise transcribes the audio locally with
[whisper](https://github.com/openai/whisper). Either way, the raw caption text is
reflowed into readable paragraphs and written to a timestamped `.txt` file.

---

## Requirements

The script is a thin wrapper — it installs nothing and shells out to tools that
must already be on your `PATH`:

| Tool      | Used for                                   | Required?                        |
| --------- | ------------------------------------------ | -------------------------------- |
| `yt-dlp`  | fetching metadata, captions, and audio     | **yes**                          |
| `ffmpeg`  | audio extraction (invoked by yt-dlp)       | yes, for the transcription path  |
| `whisper` | transcribing audio when no captions exist  | only for the fallback path       |

Install on macOS (Homebrew):

```bash
brew install yt-dlp ffmpeg
pip install -U openai-whisper      # only if you need the transcription fallback
```

> **Note:** On this machine `whisper` lives in Python 3.12's framework `bin`, while the
> default `python3` is 3.14. The script calls the `whisper` **binary** directly, so the
> version split does not matter — as long as `whisper` resolves on `PATH`.

---

## Installation

The script is already symlinked as `ytt` and set up for unquoted URLs:

```bash
# symlink onto PATH
ln -sf /Users/tchung/claude/yt-transcript/yt-transcript.sh ~/bin/ytt

# in ~/.zshrc — lets you paste URLs with ? and & without quoting them
alias ytt='noglob ytt'
```

`noglob` matters because zsh treats `?` and `&` in a YouTube URL as glob
characters and errors with `zsh: no matches found` before the script ever runs.
With the alias, `ytt <url>` works bare; without it, quote the URL.

---

## Usage

```bash
ytt <youtube-url-or-id> [-o output_dir] [-l lang] [-m whisper_model] [-k]
```

| Option | Meaning                                          | Default             |
| ------ | ------------------------------------------------ | ------------------- |
| `-o`   | output directory                                 | current directory   |
| `-l`   | caption language                                 | `en`                |
| `-m`   | whisper model for the transcription fallback     | `small`             |
| `-k`   | keep intermediate files (`.vtt` / audio)         | off (files deleted) |
| `-h`   | show help                                        | —                   |

### Examples

```bash
# Simplest — save transcript to the current directory
ytt https://www.youtube.com/watch?v=JpJaEPGzPF4

# Bare video ID works too
ytt JpJaEPGzPF4

# Choose an output folder and a non-English caption track
ytt -o ~/transcripts -l es https://youtu.be/VIDEO_ID

# Force a more accurate whisper model on the fallback path, and keep the audio
ytt -m medium -k https://youtu.be/VIDEO_ID
```

### What it prints

```
>> Title   : Finally, The CORRECT Way to Run Local AI on a Mac
   Channel : Samuel Gregory
   Length  : 9m 3s
   Uploaded: 2026-06-30
   Views   : 23362
>> Checking for captions (en)...
>> Found captions — converting to text.
>> Saved: ./ytt_20260706_213414.txt
```

Output filename is always `ytt_YYYYMMDD_HHMMSS.txt` — the timestamp keeps runs from
colliding. The video title is shown on screen but not used in the filename.

---

## Using it as a Claude Skill

The script is also packaged as a Claude Skill (`yt-transcript-skill.zip`) so Claude
can run it for you when you paste a YouTube link. Upload the zip via **Settings →
Skills → Add → Upload skill**. The zip contains `SKILL.md` (name + description +
instructions) and `yt-transcript.sh`.

Once installed, just ask naturally — e.g. *"Get me the transcript from <url>"* — and
the skill triggers automatically.

### One-time setup in the Claude Desktop sandbox

The desktop app runs skill code in a sandbox that **blocks network egress by
default**, so a few one-time steps are needed before it can reach YouTube:

1. **Whitelist the domains.** In **Settings → Capabilities → Domain allowlist →
   Additional allowed domains**, add all three:
   - `www.youtube.com` — page + `api/timedtext` caption endpoint
   - `youtubei.googleapis.com` — yt-dlp's InnerTube metadata API
   - `*.googlevideo.com` — caption/audio data stream (must be a wildcard)
2. **Start a fresh chat.** Allowlist changes only apply to a newly-provisioned
   sandbox — an existing chat keeps returning `403 host_not_allowed`.

Notes:
- `yt-dlp` is not preinstalled in the sandbox; the skill's preflight installs it
  with `pip` on first run.
- The sandbox routes traffic through a TLS-intercepting proxy with a self-signed
  CA. There is **nothing to bundle** — the correct CA is already in the system
  trust store; the skill points yt-dlp at it (`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`,
  with a `certifi` append as fallback). Never use `--no-check-certificates`.
- On your **own machine** (or a Claude Code session) none of this applies — there
  is no sandbox, so the script just runs.

See `SKILL.md` inside the zip for the full preflight instructions Claude follows.

---

## How it works

### 1. Metadata

A single `yt-dlp --skip-download --print ...` call fetches title, duration, channel,
upload date, and view count. Each field uses its own `--print` flag (one value per
line) rather than a `\t`-joined template, because this yt-dlp build does not expand
`\t` inside a print template. Duration is fetched in raw seconds and formatted by
`fmt_duration` into `1h 2m 3s`, dropping leading zero units (a 45s clip shows `45s`).

### 2. Caption path (preferred)

```
yt-dlp --write-sub --write-auto-sub --sub-lang <lang> --sub-format vtt
```

downloads manual captions if present, else auto-generated ones, as a VTT file into a
temporary directory. If a `.vtt` is found, the script converts it and exits before
ever touching the fallback.

The `vtt_to_text` function cleans and **reflows** the captions:

1. `sed` strips the `WEBVTT` header, `Kind:`/`Language:` lines, timestamp cue lines
   (`-->`), inline `<...>` tags, carriage returns, and blank lines.
2. `awk` drops consecutive duplicate lines (rolling auto-captions repeat each line),
   reassembles all the words into one continuous string, splits it into sentences on
   `.!?` boundaries, and emits a blank line every `PARA_SENTENCES` sentences.

The result is prose in short paragraphs instead of the ragged ~40-character lines
captions are stored as. Tune readability by editing `PARA_SENTENCES` near the top of
the function (default `4`).

> All newline insertion happens in `awk`, **not** `sed` — macOS/BSD `sed` does not
> expand `\n` in a replacement, so doing it in `sed` would fail silently.

### 3. Transcription fallback

Only runs when the video has no captions:

```
yt-dlp -x --audio-format m4a   # extract audio
whisper audio.m4a --model <model> --output_format txt
```

The whisper `.txt` is copied to the output file as-is. (Whisper already emits
sentence-per-line-ish output; it is not run through the paragraph reflow.)

`yt-dlp` and `whisper` are fully silenced (`--quiet ... >/dev/null 2>&1`); only the
script's own `>>` status lines reach the console. To debug a download failure,
temporarily remove those redirects.

---

## Notes & limitations

- **Filename collisions**: two runs in the same second would overwrite; in practice
  download latency prevents this.
- **Sentence splitting** is punctuation-based, so abbreviations like "e.g." can start
  a new paragraph occasionally. Good enough for reading; not linguistically perfect.
- **Language**: `-l` selects the caption track; if that language is unavailable the
  caption path finds nothing and (for the `en` default) whisper transcribes instead.
- **`set -euo pipefail`** is on. Optional command substitutions (e.g. the `find`
  calls) are guarded with `|| true` so an empty result does not abort the script.
