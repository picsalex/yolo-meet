"""Export every official YOLO26 task x size to an FP16 Core AI `.aimodel`, zipped as `<name>.aimodel.zip` for release.

Needs macOS 26+ on Apple silicon (or x86_64 Linux):
    uv venv --python 3.13 && uv pip install "ultralytics>=8.4.163" "coreai-torch>=0.4.3" "torch<=2.13.0"
    uv run python scripts/export_models.py --output exports
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

from ultralytics import YOLO

# Suffix and input size per task, matching ModelCatalog in Sources/YoloMeetCore/ModelStore.swift.
TASKS = {"": 640, "-seg": 640, "-pose": 640, "-obb": 640, "-cls": 224, "-sem": 640, "-depth": 640}
SIZES = "nsmlx"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("exports"))
    parser.add_argument("--sizes", default=SIZES)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    for size in args.sizes:
        for suffix, imgsz in TASKS.items():
            name = f"yolo26{size}{suffix}"
            archive = args.output / f"{name}.aimodel.zip"
            if archive.exists():
                continue
            # Raw head (no embedded NMS): the app decodes and runs NMS in Swift. FP16 halves size and runs on the ANE.
            exported = Path(YOLO(f"{name}.pt").export(format="coreai", quantize=16, imgsz=imgsz))
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(exported), str(archive)], check=True)
            shutil.rmtree(exported)
            print(f"exported {archive}", flush=True)


if __name__ == "__main__":
    main()
