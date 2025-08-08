from __future__ import annotations
from typing import Any, Dict, List, Tuple
from PIL import Image, ImageStat

class PixelAnalyzer:
    def __init__(self, top_colors: int = 5):
        self.top_colors = max(2, int(top_colors))

    def analyze(self, img: Image.Image) -> Dict[str, Any]:
        stats = ImageStat.Stat(img.convert("RGB"))
        width, height = img.size
        avg_r, avg_g, avg_b = [float(x) for x in stats.mean]
        extrema = stats.extrema
        histogram = img.convert("RGB").histogram()

        quantized = img.convert("RGB").quantize(colors=self.top_colors, method=Image.MEDIANCUT)
        palette = quantized.getpalette()
        counts = {}
        for color_index in quantized.getdata():
            counts[color_index] = counts.get(color_index, 0) + 1

        palette_colors: List[Tuple[int, int, int]] = []
        if palette:
            for idx, cnt in sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[: self.top_colors]:
                base = idx * 3
                r, g, b = palette[base:base+3]
                palette_colors.append((r, g, b))

        return {
            "width": width,
            "height": height,
            "mode": img.mode,
            "average_color_rgb": [avg_r, avg_g, avg_b],
            "channel_extrema": {
                "R": list(extrema[0]),
                "G": list(extrema[1]),
                "B": list(extrema[2]),
            } if len(extrema) >= 3 else None,
            "dominant_colors_rgb": palette_colors,
            "histogram_256bins_per_channel": {
                "R": histogram[0:256],
                "G": histogram[256:512],
                "B": histogram[512:768],
            },
        }
