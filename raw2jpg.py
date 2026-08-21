#!/usr/bin/env python3
"""
raw2jpg.py — batch RAW → JPG converter for RawDeck users.

Designed for the "drop a card, dump out JPGs" workflow on macOS,
but runs anywhere Python 3.8+ with `rawpy`, `Pillow`, `tqdm` installed.

Usage:
    python3 raw2jpg.py <input_folder> <output_folder>
    python3 raw2jpg.py ~/Pictures/SD_CARD ~/Desktop/jpg_out --quality 90
    python3 raw2jpg.py ./raw ./jpg --workers 6 --recursive
"""

import argparse
import concurrent.futures
import sys
from pathlib import Path

from PIL import Image
from tqdm import tqdm

try:
    import rawpy
except ImportError:
    sys.exit(
        "rawpy not installed.\n"
        "Install once:  pip3 install rawpy Pillow tqdm\n"
        "(macOS Apple Silicon note: works fine; on Intel Macs brew install libraw first)"
    )

# RAW file extensions recognised
RAW_EXT = {
    ".cr2", ".cr3",              # Canon
    ".nef", ".nrw",              # Nikon
    ".arw", ".srf", ".sr2",      # Sony
    ".raf",                      # Fujifilm
    ".dng",                      # Adobe universal
    ".orf",                      # Olympus
    ".rw2",                      # Panasonic
    ".pef",                      # Pentax
    ".3fr", ".fff",              # Hasselblad
    ".x3f",                      # Sigma
    ".mrw",                      # Minolta/Konica
    ".rwl", ".rwz",              # Leica
}

# Files that look RAW-ish but actually decode OK as plain images
DECODE_DIRECTLY = {".dng"}  # we still run through rawpy for consistency


def find_raws(src: Path, recursive: bool) -> list[Path]:
    if recursive:
        return sorted(
            p for p in src.rglob("*") if p.is_file() and p.suffix.lower() in RAW_EXT
        )
    return sorted(
        p for p in src.iterdir() if p.is_file() and p.suffix.lower() in RAW_EXT
    )


def convert(src: Path, out_dir: Path, quality: int, overwrite: bool) -> tuple[str, int]:
    """Returns (status, bytes_written). status is 'ok', 'skip', or 'fail:<reason>'."""
    out = out_dir / (src.stem + ".jpg")
    if out.exists() and not overwrite:
        return ("skip", 0)
    try:
        with rawpy.imread(str(src)) as raw:
            rgb = raw.postprocess(
                demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD,
                half_size=False,
                no_auto_bright=True,
                use_camera_wb=True,
                output_color=rawpy.ColorSpace.sRGB,
            )
        img = Image.fromarray(rgb)
        # EXIF: rawpy strips it on postprocess; pull what we can from the raw container
        # (most camera/shot metadata). For full EXIF, install exifread and stitch.
        img.save(out, "JPEG", quality=quality, optimize=True)
        return ("ok", out.stat().st_size)
    except Exception as e:
        return (f"fail:{type(e).__name__}: {e}", 0)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Batch RAW → JPG converter (companion tool for RawDeck)."
    )
    ap.add_argument("input", type=Path, help="folder containing RAW files")
    ap.add_argument("output", type=Path, help="folder to write JPGs into")
    ap.add_argument(
        "--quality", type=int, default=90, help="JPEG quality 1–100 (default 90)"
    )
    ap.add_argument(
        "--workers", type=int, default=4, help="parallel threads (default 4)"
    )
    ap.add_argument(
        "--recursive", action="store_true", help="scan input folder recursively"
    )
    ap.add_argument(
        "--overwrite", action="store_true", help="re-convert even if .jpg exists"
    )
    args = ap.parse_args()

    src = args.input.expanduser().resolve()
    dst = args.output.expanduser().resolve()
    if not src.is_dir():
        ap.error(f"input folder not found: {src}")
    dst.mkdir(parents=True, exist_ok=True)

    files = find_raws(src, args.recursive)
    if not files:
        print(f"No RAW files found in {src}", file=sys.stderr)
        return 1

    print(
        f"{len(files)} RAW files → {dst}\n"
        f"  quality={args.quality}  workers={args.workers}  "
        f"recursive={args.recursive}  overwrite={args.overwrite}"
    )

    ok = skip = fail = total_bytes = 0
    fails: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futures = {
            ex.submit(convert, f, dst, args.quality, args.overwrite): f for f in files
        }
        for fut in tqdm(
            concurrent.futures.as_completed(futures),
            total=len(futures),
            unit="img",
        ):
            status, nbytes = fut.result()
            if status == "ok":
                ok += 1
                total_bytes += nbytes
            elif status == "skip":
                skip += 1
            else:
                fail += 1
                fails.append(f"  {futures[fut].name}: {status[5:]}")

    mb = total_bytes / 1024 / 1024
    print(
        f"\nDone: {ok} converted ({mb:.1f} MB), {skip} skipped, {fail} failed "
        f"of {len(files)} total"
    )
    if fails:
        print("\nFailures:")
        for line in fails:
            print(line)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
