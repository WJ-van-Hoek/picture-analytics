from __future__ import annotations
from typing import Any, Dict, Optional
from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS
from PIL.TiffImagePlugin import IFDRational

def _to_float(x) -> Optional[float]:
    try:
        if isinstance(x, IFDRational):
            return float(x)
        if isinstance(x, (tuple, list)) and len(x) == 2:
            a, b = x
            a = float(a if not isinstance(a, IFDRational) else float(a))
            b = float(b if not isinstance(b, IFDRational) else float(b))
            return a / b if b else None
        if isinstance(x, (int, float)):
            return float(x)
    except Exception:
        return None
    return None

def parse_gps(self, exif: Dict[str, Any]) -> Dict[str, Any]:
    gps = exif.get("GPSInfo")
    if not isinstance(gps, dict):
        return {}
    lat = dms_to_degrees(gps.get("GPSLatitude"), gps.get("GPSLatitudeRef"))
    lon = dms_to_degrees(gps.get("GPSLongitude"), gps.get("GPSLongitudeRef"))
    out = {}
    if lat is not None and lon is not None:
        out["latitude"] = lat
        out["longitude"] = lon
    return out

def dms_to_degrees(dms, ref) -> Optional[float]:
    try:
        if not dms or len(dms) != 3:
            return None
        deg = _to_float(dms[0])
        mins = _to_float(dms[1])
        secs = _to_float(dms[2])
        if None in (deg, mins, secs):
            return None
        dec = deg + mins / 60.0 + secs / 3600.0
        if ref in ["S", "W"]:
            dec = -dec
        return dec
    except Exception:
        return None

class ExifExtractor:
    def extract(self, img: Image.Image) -> Dict[str, Any]:
        exif_info: Dict[str, Any] = {}
        try:
            exif = img.getexif()
            if exif:
                for tag_id, value in exif.items():
                    tag_name = TAGS.get(tag_id, str(tag_id))
                    if isinstance(value, bytes):
                        try:
                            value = value.decode("utf-8", errors="replace")
                        except Exception:
                            value = str(value)
                    if tag_name == "GPSInfo" and isinstance(value, dict):
                        gps_data: Dict[str, Any] = {}
                        for k, v in value.items():
                            gps_tag = GPSTAGS.get(k, str(k))
                            gps_data[gps_tag] = v
                        exif_info[tag_name] = gps_data
                    else:
                        exif_info[tag_name] = value
        except Exception as e:
            exif_info["error"] = f"Failed to read EXIF: {e}"
        return exif_info
