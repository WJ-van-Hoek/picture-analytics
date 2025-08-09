from __future__ import annotations
import hashlib
from pathlib import Path
from typing import Any, Dict
from PIL import Image
from PIL.TiffImagePlugin import IFDRational

class JsonSanitizer:
    @staticmethod
    def sanitize(obj: Any) -> Any:
        if obj is None or isinstance(obj, (bool, int, float, str)):
            return obj
        if isinstance(obj, IFDRational):
            try:
                return float(obj)
            except Exception:
                return None
        if isinstance(obj, (bytes, bytearray)):
            try:
                return obj.decode("utf-8", "replace")
            except Exception:
                return obj.hex()
        if isinstance(obj, Image.Image):
            return f"<PIL.Image mode={obj.mode} size={obj.size}>"
        if isinstance(obj, dict):
            return {str(JsonSanitizer.sanitize(k)): JsonSanitizer.sanitize(v) for k, v in obj.items()}
        if isinstance(obj, (list, tuple, set)):
            return [JsonSanitizer.sanitize(x) for x in obj]
        try:
            return float(obj)
        except Exception:
            return str(obj)

def read_file_info(path: Path) -> Dict[str, Any]:
    data = path.read_bytes()
    import hashlib as _h
    sha256 = _h.sha256(data).hexdigest()
    size_bytes = len(data)
    return {"path": str(path), "filename": path.name, "size_bytes": size_bytes, "sha256": sha256, "extension": path.suffix.lower()}
