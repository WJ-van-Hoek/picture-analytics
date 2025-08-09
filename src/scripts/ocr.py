from __future__ import annotations
from typing import Any, Dict
from PIL import Image, ImageOps
try:
    import pytesseract  # type: ignore
    _HAVE_PYTESSERACT = True
except Exception:
    _HAVE_PYTESSERACT = False

class OCRRunner:
    def __init__(self, lang: str = "eng"):
        self.lang = lang
    @property
    def available(self) -> bool:
        return _HAVE_PYTESSERACT
    def run(self, image: Image.Image) -> Dict[str, Any]:
        if not self.available:
            return {"enabled": False, "error": "pytesseract not installed. Install with `pip install pytesseract` and ensure Tesseract OCR engine is installed."}
        try:
            prep = ImageOps.grayscale(image)
            text = pytesseract.image_to_string(prep, lang=self.lang)
            return {"enabled": True, "language": self.lang, "text": text}
        except Exception as e:
            return {"enabled": True, "error": f"OCR failed: {e}"}
