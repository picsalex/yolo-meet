"""Export the model catalog to Core AI `.aimodel` assets, zipped as `<name>.aimodel.zip` for release.

Every asset carries the app's metadata keys (task, names, family, architecture, params, gflops). Re-running is
idempotent: existing archives are skipped, or only re-stamped when they predate a metadata key.

Needs macOS 26+ on Apple silicon (or x86_64 Linux):
    uv venv --python 3.13
    uv pip install "ultralytics>=8.4.163" "rfdetr==1.12.0" "coreai-torch>=0.4.3" "torch<=2.13.0"
    uv run python scripts/export_models.py --output exports
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import torch
from torch.utils.flop_counter import FlopCounterMode

# Names and tasks must match ModelCatalog in Sources/YoloMeetCore/ModelStore.swift.
YOLO_TASKS = {"": 640, "-seg": 640, "-pose": 640, "-obb": 640, "-cls": 224, "-sem": 640, "-depth": 640}
YOLO_VERSIONS = {
    "yolov5": [""],  # anchor-free "u" detection models, e.g. yolov5nu
    "yolov8": ["", "-seg", "-pose", "-obb", "-cls"],
    "yolo11": ["", "-seg", "-pose", "-obb", "-cls"],
    "yolo26": ["", "-seg", "-pose", "-obb", "-cls", "-sem", "-depth"],
}
# Apache-2.0 RF-DETR checkpoints: (asset name, rfdetr class, precision).
RFDETR = [
    *[(f"rfdetr-{s}", f"RFDETR{s.title()}", "float16") for s in ("nano", "small", "medium", "large")],
    *[(f"rfdetr-seg-{s}", f"RFDETRSeg{c}", "float16") for s, c in [
        ("nano", "Nano"), ("small", "Small"), ("medium", "Medium"), ("large", "Large"), ("xlarge", "XLarge"),
        ("2xlarge", "2XLarge")]],
    ("rfdetr-pose", "RFDETRKeypointPreview", "float32"),  # float16 keypoint graphs crash on the Neural Engine
]
STATS = ("params", "gflops", "architecture")


def yolo_name(version: str, size: str, suffix: str) -> str:
    """Asset name, e.g. yolo26n-seg, yolo11s, yolov5mu."""
    return f"{version}{size}{'u' if version == 'yolov5' else ''}{suffix}"


def stamp(asset: Path, fields: dict[str, str]) -> None:
    """Merge app metadata into the asset's creator-defined metadata (strings, like Ultralytics' own keys)."""
    path = asset / "metadata.json"
    data = json.loads(path.read_text())
    data.setdefault("creatorDefinedMetadata", {}).update(fields)
    path.write_text(json.dumps(data, indent=2))


def archive(asset: Path, destination: Path) -> None:
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(asset), str(destination)], check=True)
    shutil.rmtree(asset)
    print(f"wrote {destination}", flush=True)


def yolo_stats(name: str, imgsz: int) -> dict[str, str]:
    from ultralytics import YOLO
    from ultralytics.utils.torch_utils import get_flops, get_num_params

    model = YOLO(f"{name}.pt").model
    return {"architecture": "CNN", "params": str(get_num_params(model)), "gflops": f"{get_flops(model, imgsz):.1f}"}


def rfdetr_stats(network: torch.nn.Module, resolution: int) -> dict[str, str]:
    network = network.eval().cpu()
    with FlopCounterMode(display=False) as counter:  # not under no_grad: the module tracker needs grad hooks
        network(torch.zeros(1, 3, resolution, resolution))
    params = sum(p.numel() for p in network.parameters())
    return {"architecture": "Transformer", "params": str(params), "gflops": f"{counter.get_total_flops() / 1e9:.1f}"}


def export_yolo(name: str, imgsz: int, out: Path) -> None:
    from ultralytics import YOLO

    # Raw head (no embedded NMS): the app decodes and runs NMS in Swift. FP16 runs on the Neural Engine.
    asset = Path(YOLO(f"{name}.pt").export(format="coreai", quantize=16, imgsz=imgsz))
    stamp(asset, {"family": "yolo", **yolo_stats(name, imgsz)})
    archive(asset, out / f"{name}.aimodel.zip")


def export_rfdetr(name: str, cls: str, precision: str, out: Path) -> None:
    import rfdetr

    detector = getattr(rfdetr, cls)()
    with tempfile.TemporaryDirectory() as tmp:
        asset = Path(detector.export(output_dir=tmp, format="coreai", coreai_precision=precision, output_name=name))
        meta = json.loads(asset.with_name(asset.name + ".rfdetr.json").read_text())["metadata"]
        names = ", ".join(f"{k}: {v!r}" for k, v in meta["class_id_to_name"].items())
        size = meta["input_shape"][2]
        stamp(asset, {
            "family": "rfdetr",
            "task": {"detect": "detect", "segment": "segment", "keypoints": "pose"}[meta["task"]],
            "names": f"{{{names}}}",  # keys are the model's class slots (COCO category ids)
            "imgsz": str([size, size]),
            "mean": str(meta.get("means", [0.485, 0.456, 0.406])),
            "std": str(meta.get("stds", [0.229, 0.224, 0.225])),
            **rfdetr_stats(detector.model.model, size),
        })
        archive(asset, out / f"{name}.aimodel.zip")


def restamp(path: Path, fields: dict[str, str]) -> None:
    """Add metadata to an existing archive without re-exporting the model."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["ditto", "-x", "-k", str(path), tmp], check=True)
        asset = next(Path(tmp).glob("*.aimodel"))
        stamp(asset, fields)
        path.unlink()
        archive(asset, path)


def has_stats(path: Path) -> bool:
    listing = subprocess.run(["unzip", "-p", str(path), "*/metadata.json"], capture_output=True, text=True).stdout
    return all(f'"{key}"' in listing for key in STATS)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("exports"))
    parser.add_argument("--families", nargs="+", choices=[*YOLO_VERSIONS, "rfdetr"], default=[*YOLO_VERSIONS, "rfdetr"])
    parser.add_argument("--sizes", default="nsmlx", help="YOLO sizes")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    for version in (v for v in YOLO_VERSIONS if v in args.families):
        for size in args.sizes:
            for suffix in YOLO_VERSIONS[version]:
                name = yolo_name(version, size, suffix)
                path = args.output / f"{name}.aimodel.zip"
                if not path.exists():
                    export_yolo(name, YOLO_TASKS[suffix], args.output)
                elif not has_stats(path):
                    restamp(path, {"family": "yolo", **yolo_stats(name, YOLO_TASKS[suffix])})

    if "rfdetr" in args.families:
        for name, cls, precision in RFDETR:
            if not (args.output / f"{name}.aimodel.zip").exists():
                export_rfdetr(name, cls, precision, args.output)


if __name__ == "__main__":
    main()
