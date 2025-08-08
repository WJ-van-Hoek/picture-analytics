# src/analytics/cli.py
from __future__ import annotations
import argparse
from pathlib import Path
from .pipeline import AnalyticsPipeline

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Mini-analytics: EXIF, GPS, pixels, OCR, convert/resize.")
    p.add_argument("-i", "--input", required=True, help="Path to input image.")
    p.add_argument("-o", "--outdir", default="out", help="Output directory.")
    p.add_argument("--ocr", action="store_true", help="Run OCR.")
    p.add_argument("--ocr-lang", default="eng", help="Tesseract languages, e.g. 'eng' or 'nld+eng'.")
    p.add_argument("--max-dim", type=int, default=0, help="Resize so longest edge equals this value.")
    p.add_argument("--format", default="", help="If set (e.g. 'png' or 'jpeg'), write converted copy.")
    p.add_argument("--report-name", default="", help="Optional JSON report filename.")
    return p

def main():
    args = build_parser().parse_args()
    in_path = Path(args.input)
    outdir = Path(args.outdir)
    pipeline = AnalyticsPipeline(
        outdir=outdir,
        ocr_lang=args.ocr_lang,
        run_ocr=args.ocr,
        max_dim=args.max_dim,
        out_format=args.format,
    )
    report = pipeline.process_image(in_path, report_name=args.report_name or None)
    print(f"Wrote report to: {(outdir / (args.report_name or f'{in_path.stem}_report.json')).resolve()}")
    if report.get("converted"):
        print(f"Wrote converted image: {report['converted']['output_path']}")
