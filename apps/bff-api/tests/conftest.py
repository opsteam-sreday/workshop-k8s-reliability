import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / "apps" / "bff-api"), str(ROOT / "apps" / "shared")]
os.environ["OTEL_SDK_DISABLED"] = "true"
