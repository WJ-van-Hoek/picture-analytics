from __future__ import annotations
import json
from pathlib import Path
from typing import Any, Dict, Optional
from PIL import Image

from . import exif
from .utils import JsonSanitizer, read_file_info
from .exif import ExifExtractor
from .pixels import PixelAnalyzer
from .ocr import OCRRunner
from .convert import ImageConverter

class AnalyticsPipeline:
    def __init__(self, outdir: Path, ocr_lang: str = "eng", run_ocr: bool = False, max_dim: int = 0, out_format: str = ""):
        self.outdir = outdir
        self.ocr_lang = ocr_lang
        self.run_ocr_flag = run_ocr
        self.max_dim = max_dim
        self.out_format = out_format
        self.exif = ExifExtractor()
        self.pixels = PixelAnalyzer()
        self.ocr = OCRRunner(lang=ocr_lang)
        self.converter = ImageConverter(max_dim=max_dim, out_format=out_format)
        self.outdir.mkdir(parents=True, exist_ok=True)
    def process_image(self, in_path: Path, report_name: Optional[str] = None) -> Dict[str, Any]:
        if not in_path.exists():
            raise FileNotFoundError(f"Input not found: {in_path}")
        with Image.open(in_path) as img:
            img.load()
            report: Dict[str, Any] = {
                "file_info": read_file_info(in_path),
                "image_info": {"format_detected": img.format, "mode": img.mode, "size": {"width": img.width, "height": img.height}},
                "exif": self.exif.extract(img),
                "gps": {},
                "pixel_stats": self.pixels.analyze(img),
                "ocr": None,
                "converted": None,
            }
            try:
                report["gps"] = exif.parse_gps(report["exif"]) or {}
            except Exception:
                report["gps"] = {}
            if self.run_ocr_flag:
                report["ocr"] = self.ocr.run(img)
            if self.out_format:
                base = in_path.stem
                out_ext = self.out_format.lower().replace("jpg", "jpeg")
                out_name = f"{base}_converted.{out_ext}"
                out_path = self.outdir / out_name
                report["converted"] = self.converter.convert(img, out_path)
            safe_report = JsonSanitizer.sanitize(report)
            report_name = report_name or f"{in_path.stem}_report.json"
            report_path = self.outdir / report_name
            with open(report_path, "w", encoding="utf-8") as f:
                json.dump(safe_report, f, indent=2)
            return report
