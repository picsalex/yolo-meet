"""Export MediaPipe's hand, pose and face landmarkers to Core AI, zipped as `<name>.aimodel.zip` for release.

Each model is a folder with `detector.aimodel`, `landmarks.aimodel` and `metadata.json`; the app runs MediaPipe's
two-stage pipeline (detector, rotated crop, landmarks) in Swift (Sources/YoloMeetCore/Landmarker.swift).
Every conversion step is checked against the previous runtime: TFLite (LiteRT) → ONNX (onnxruntime) → Core AI.

`--reference <images>` also writes MediaPipe Tasks' own landmarks for those images (reference.json), which
Tests/YoloMeetCoreTests/LandmarkerTests.swift compares against.

Needs macOS 26+ on Apple silicon:
    uv venv --python 3.12
    uv pip install tensorflow tf2onnx coreai-onnx ai-edge-litert onnxruntime mediapipe
    uv run python scripts/export_mediapipe.py --output exports
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import onnx.utils
import onnxruntime as ort
import tf2onnx
from ai_edge_litert.interpreter import Interpreter, OpResolverType

import coreai_onnx

TASKS = "https://storage.googleapis.com/mediapipe-models"
# App model name: (task, MediaPipe bundle, landmark outputs to keep). Pose keeps its heatmap for MediaPipe's refinement.
MODELS = {
    "mediapipe-hand": ("hand", "hand_landmarker/hand_landmarker", ["Identity", "Identity_1", "Identity_2"]),
    "mediapipe-pose-lite": ("pose", "pose_landmarker/pose_landmarker_lite", ["Identity", "Identity_1", "Identity_3"]),
    "mediapipe-pose-full": ("pose", "pose_landmarker/pose_landmarker_full", ["Identity", "Identity_1", "Identity_3"]),
    "mediapipe-pose-heavy": ("pose", "pose_landmarker/pose_landmarker_heavy", ["Identity", "Identity_1", "Identity_3"]),
    "mediapipe-face": ("face", "face_landmarker/face_landmarker", ["Identity", "Identity_1"]),
}
def task_url(bundle: str) -> str:
    """MediaPipe Tasks bundle, e.g. pose_landmarker/pose_landmarker_lite."""
    return f"{TASKS}/{bundle}/float16/latest/{bundle.split('/')[1]}.task"


DETECTOR = {"hand": "hand_detector", "pose": "pose_detector", "face": "face_detector"}
LANDMARKS = {"hand": "hand_landmarks_detector", "pose": "pose_landmarks_detector", "face": "face_landmarks_detector"}


def densify(src: Path, dst: Path) -> None:
    """Rewrite sparse weights (DENSIFY ops, used by the pose detector) as dense constants, which tf2onnx can read."""
    from tensorflow.lite.python import schema_py_generated as schema
    from tensorflow.lite.tools import flatbuffer_utils

    # Reference kernels: the XNNPACK delegate takes over these layers and never fills the DENSIFY outputs.
    interp = Interpreter(
        model_path=str(src), experimental_preserve_all_tensors=True,
        experimental_op_resolver_type=OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    interp.set_tensor(inp["index"], np.zeros(inp["shape"], np.float32))
    interp.invoke()
    model = flatbuffer_utils.read_model(str(src))
    graph = model.subgraphs[0]
    codes = [max(c.builtinCode, c.deprecatedBuiltinCode) for c in model.operatorCodes]
    kept = []
    for op in graph.operators:
        if codes[op.opcodeIndex] != schema.BuiltinOperator.DENSIFY:
            kept.append(op)
            continue
        dense = interp.get_tensor(op.outputs[0])
        assert np.count_nonzero(dense), "densified to zeros"
        buffer = schema.BufferT()
        buffer.data = np.frombuffer(dense.tobytes(), np.uint8)
        model.buffers.append(buffer)
        for tensor in (graph.tensors[op.outputs[0]], graph.tensors[op.inputs[0]]):  # tf2onnx parses both
            tensor.buffer, tensor.sparsity = len(model.buffers) - 1, None
    graph.operators = kept
    flatbuffer_utils.write_model(model, str(dst))


def convert(tflite: Path, asset: Path, keep: list[str] | None = None) -> None:
    """TFLite → ONNX (NCHW image input) → Core AI, each checked against the previous runtime."""
    with tempfile.TemporaryDirectory() as tmp:
        onnx_path = Path(tmp) / "model.onnx"
        interp = Interpreter(model_path=str(tflite))
        interp.allocate_tensors()
        inp = interp.get_input_details()[0]
        tf2onnx.convert.from_tflite(str(tflite), opset=17, inputs_as_nchw=[inp["name"]], output_path=str(onnx_path))
        x = np.random.default_rng(0).random(inp["shape"], dtype=np.float32)
        interp.set_tensor(inp["index"], x)
        interp.invoke()
        session = ort.InferenceSession(str(onnx_path))
        got = session.run(None, {session.get_inputs()[0].name: x.transpose(0, 3, 1, 2)})
        for detail, value in zip(interp.get_output_details(), got):
            if keep and detail["name"] not in keep:
                continue  # dropped below (e.g. pose's segmentation mask)
            error = np.abs(interp.get_tensor(detail["index"]).reshape(value.shape) - value).max()
            assert error < 1e-2, f"{tflite.name} {detail['name']}: TFLite vs ONNX differ by {error}"
        if keep:
            onnx.utils.extract_model(str(onnx_path), str(onnx_path), [session.get_inputs()[0].name], keep)
        coreai_onnx.convert(str(onnx_path)).save_asset(asset)
        report = asyncio.run(coreai_onnx.verify(str(onnx_path), asset))
        for output in report.outputs:  # FP16 on the Neural Engine: judge by PSNR rather than strict tolerances
            assert output.psnr > 50 or output.max_abs_error < 1e-3, f"{asset.name} {output.name}: {output}"
        print(f"  {asset.name}: " + ", ".join(f"{o.name} {o.psnr:.0f} dB" for o in report.outputs), flush=True)


def export(name: str, out: Path) -> None:
    task, bundle, keep = MODELS[name]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        urllib.request.urlretrieve(task_url(bundle), tmp / "m.task")
        zipfile.ZipFile(tmp / "m.task").extractall(tmp)
        asset = tmp / f"{name}.aimodel"
        asset.mkdir()
        detector = tmp / f"{DETECTOR[task]}.tflite"
        if task == "pose":
            densify(detector, tmp / "detector_dense.tflite")
            detector = tmp / "detector_dense.tflite"
        convert(detector, asset / "detector.aimodel")
        convert(tmp / f"{LANDMARKS[task]}.tflite", asset / "landmarks.aimodel", keep)
        metadata = {"family": "mediapipe", "task": task, "architecture": "CNN", "source": f"{TASKS}/{bundle}"}
        (asset / "metadata.json").write_text(json.dumps({"creatorDefinedMetadata": metadata}, indent=2))
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(asset), str(out / f"{name}.aimodel.zip")], check=True)
        print(f"wrote {out / f'{name}.aimodel.zip'}", flush=True)


def reference(images: Path, out: Path) -> None:
    """MediaPipe Tasks' normalized landmarks for the test images."""
    import mediapipe as mp
    from mediapipe.tasks.python import BaseOptions, vision

    images_for = {"hand": ["woman_hands.jpg", "thumb_up.jpg"], "pose": ["pose.jpg"], "face": ["portrait.jpg"]}
    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        for kind, bundle, _ in MODELS.values():
            path = Path(tmp) / "m.task"
            urllib.request.urlretrieve(task_url(bundle), path)
            options = {"hand": lambda b: vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(base_options=b, num_hands=2)),
                       "pose": lambda b: vision.PoseLandmarker.create_from_options(vision.PoseLandmarkerOptions(base_options=b)),
                       "face": lambda b: vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(base_options=b))}[kind]
            for file in images_for[kind]:
                with options(BaseOptions(model_asset_path=str(path))) as landmarker:
                    result = landmarker.detect(mp.Image.create_from_file(str(images / file)))
                groups = getattr(result, f"{kind}_landmarks")
                results[f"{bundle.split('/')[1]}/{file}"] = {"landmarks": [[[p.x, p.y] for p in g] for g in groups]}
    (out / "reference.json").write_text(json.dumps(results))
    print(f"wrote {out / 'reference.json'}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("exports"))
    parser.add_argument("--models", nargs="+", choices=MODELS, default=list(MODELS))
    parser.add_argument("--reference", type=Path, help="folder of test images: also write MediaPipe's reference.json")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name in args.models:
        if not (args.output / f"{name}.aimodel.zip").exists():
            export(name, args.output)
    if args.reference:
        reference(args.reference, args.output)


if __name__ == "__main__":
    main()
