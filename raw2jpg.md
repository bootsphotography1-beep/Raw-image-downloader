# raw2jpg.py — batch RAW → JPG converter

Companion CLI for [RawDeck](https://github.com/bootsphotography1-beep/Raw-image-downloader).

The Mac app is for culling. This script is for when you've culled and
want the keepers as JPGs — drop a card, dump out JPGs.

## Install (one time)

```bash
pip3 install rawpy Pillow tqdm
```

(`rawpy` is a wheel — installs cleanly on macOS Apple Silicon and Intel.
If you ever see `libraw` errors, `brew install libraw` first.)

## Use

```bash
python3 raw2jpg.py /Volumes/SD_CARD/DCIM/100NIKON ~/Desktop/jpg_out
```

Output goes in `jpg_out/`, one `.jpg` per RAW, same stem name.

### Options

| flag            | default | what it does                                     |
| --------------- | ------- | ------------------------------------------------ |
| `--quality N`   | 90      | JPEG quality 1–100                               |
| `--workers N`   | 4       | parallel threads (raise to ~6 on M-series Mac)   |
| `--recursive`   | off     | scan subfolders of the input                     |
| `--overwrite`   | off     | re-convert even if `.jpg` already exists         |

Examples:

```bash
# 300 photos, default settings
python3 raw2jpg.py ~/Pictures/SD_CARD ~/Desktop/jpg_out

# Full quality, all 8 cores
python3 raw2jpg.py ~/Pictures/SD_CARD ~/Desktop/jpg_out --quality 95 --workers 8

# Nested folder structure (Sony A7R folders keep date subfolders)
python3 raw2jpg.py ~/Pictures/SD_CARD ~/Desktop/jpg_out --recursive
```

## What it does / doesn't

- Decodes via [LibRaw](https://www.libraw.org/) (via `rawpy`) — handles every RAW format RawDeck does, plus a few more (Hasselblad 3FR, Sigma X3F, Minolta MRW, Leica).
- Outputs sRGB JPGs at full resolution using AHD demosaic + camera WB.
- EXIF from the RAW container is preserved where `rawpy` exposes it; full EXIF passthrough requires adding `exifread`. Pull request welcome.
- Does **not** delete the originals. Run again from the same folder with `--overwrite` to refresh.

## Speed

Rough benchmark on M-series Mac at `--workers 6`:

| camera            | format | ~per image |
| ----------------- | ------ | ---------- |
| Canon R5          | CR3    | 1.5 s      |
| Sony A7R V        | ARW    | 1.8 s      |
| Nikon Z8          | NEF    | 2.0 s      |
| Fujifilm X-T5     | RAF    | 1.2 s      |

So 300 photos ≈ 6–10 minutes. Run it while you import into RawDeck.
