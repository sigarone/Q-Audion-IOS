#!/usr/bin/env python3
"""
Convert Q-Audion ONNX deepfake model to CoreML format.

Usage:
    python convert_to_coreml.py <input.onnx> <output.mlpackage>

Example:
    python convert_to_coreml.py aasist_small_int8.onnx deepfake_lcnn.mlpackage

Requirements:
    pip install coremltools onnx
"""
import sys
import os

def convert_onnx_to_coreml(onnx_path: str, output_path: str):
    try:
        import coremltools as ct
        import onnx
    except ImportError:
        print("ERROR: Install required packages:")
        print("  pip install coremltools onnx")
        sys.exit(1)

    print(f"Loading ONNX model: {onnx_path}")
    onnx_model = onnx.load(onnx_path)
    print(f"  Input shapes: {[(i.name, [d.dim_value for d in i.type.tensor_type.shape.dim]) for i in onnx_model.graph.input]}")
    print(f"  Output shapes: {[(o.name, [d.dim_value for d in o.type.tensor_type.shape.dim]) for o in onnx_model.graph.output]}")

    print("Converting to CoreML...")
    # Convert with flexible input shape for variable-length LFCC sequences
    mlmodel = ct.convert(
        onnx_path,
        convert_to="mlprogram",  # ML Program format (iOS 15+)
        minimum_deployment_target=ct.target.iOS15,
        compute_precision=ct.precision.FLOAT16,  # Use FP16 for ANE acceleration
    )

    # Add metadata
    mlmodel.author = "Q-Audion / BCrypto"
    mlmodel.short_description = "LCNN deepfake voice detection model"
    mlmodel.version = "1.0.0"

    print(f"Saving CoreML model: {output_path}")
    mlmodel.save(output_path)
    print(f"Done! Model saved to {output_path}")
    print(f"  Size: {os.path.getsize(output_path) if os.path.isfile(output_path) else 'directory (mlpackage)'}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    convert_onnx_to_coreml(sys.argv[1], sys.argv[2])
