"""Export official Ultralytics models to FP16 Core AI `.aimodel`, zipped as `<name>.aimodel.zip` for release.

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

# Task suffix -> input size. Names and tasks must match ModelCatalog in Sources/YoloMeetCore/ModelStore.swift.
TASKS = {"": 640, "-seg": 640, "-pose": 640, "-obb": 640, "-cls": 224, "-sem": 640, "-depth": 640}
VERSIONS = {
    "yolov5": [""],  # anchor-free "u" detection models, e.g. yolov5nu
    "yolov8": ["", "-seg", "-pose", "-obb", "-cls"],
    "yolo11": ["", "-seg", "-pose", "-obb", "-cls"],
    "yolo26": ["", "-seg", "-pose", "-obb", "-cls", "-sem", "-depth"],
}


def weights(version: str, size: str, suffix: str) -> str:
    """Asset name, e.g. yolo26n-seg, yolo11s, yolov5mu."""
    return f"{version}{size}{'u' if version == 'yolov5' else ''}{suffix}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("exports"))
    parser.add_argument("--versions", nargs="+", choices=VERSIONS, default=list(VERSIONS))
    parser.add_argument("--sizes", default="nsmlx")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    for version in args.versions:
        for size in args.sizes:
            for suffix in VERSIONS[version]:
                name = weights(version, size, suffix)
                archive = args.output / f"{name}.aimodel.zip"
                if archive.exists():
                    continue
                # Raw head (no embedded NMS): the app decodes and runs NMS in Swift. FP16 runs on the Neural Engine.
                exported = Path(YOLO(f"{name}.pt").export(format="coreai", quantize=16, imgsz=TASKS[suffix]))
                subprocess.run(["ditto", "-c", "-k", "--keepParent", str(exported), str(archive)], check=True)
                shutil.rmtree(exported)
                print(f"exported {archive}", flush=True)


if __name__ == "__main__":
    main()
