from __future__ import annotations
from pathlib import Path
from typing import Any, Dict
from PIL import Image

class ImageConverter:
    def __init__(self, max_dim: int = 0, out_format: str = ""):
        self.max_dim = int(max_dim) if max_dim else 0
        self.out_format = (out_format or "").upper()
    def convert(self, img: Image.Image, out_path: Path) -> Dict[str, Any]:
        if not self.out_format:
            raise ValueError("No output format specified")
        out_format = self.out_format
        w, h = img.size
        scale = 1.0
        if self.max_dim and max(w, h) > self.max_dim:
            scale = self.max_dim / float(max(w, h))
        new_w = int(round(w * scale))
        new_h = int(round(h * scale))
        resized = img if scale == 1.0 else img.resize((new_w, new_h), Image.LANCZOS)
        save_kwargs = {}
        if out_format in {"JPEG", "JPG"}:
            out_format = "JPEG"
            save_kwargs.update({"quality": 90, "subsampling": "4:2:0", "optimize": True})
        out_path.parent.mkdir(parents=True, exist_ok=True)
        to_save = resized
        if out_format in {"JPEG", "JPG"} and resized.mode in {"RGBA", "LA"}:
            to_save = Image.new("RGB", resized.size, (255, 255, 255))
            to_save.paste(resized, mask=resized.split()[-1])
        to_save.save(out_path, format=out_format, **save_kwargs)
        return {"output_path": str(out_path), "format": out_format, "width": to_save.size[0], "height": to_save.size[1]}
