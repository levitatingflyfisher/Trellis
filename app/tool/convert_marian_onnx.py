#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "optimum==1.23.3",
#   "transformers==4.46.3",
#   "torch==2.5.1",
#   "onnx==1.17.0",
#   "onnxruntime==1.20.1",
#   "numpy==1.26.4",
#   "sentencepiece==0.2.3",
#   "tokenizers==0.20.3",
#   "huggingface-hub==0.36.2",
# ]
#
# [[tool.uv.index]]
# name = "pytorch-cpu"
# url = "https://download.pytorch.org/whl/cpu"
# explicit = true
#
# [tool.uv.sources]
# torch = { index = "pytorch-cpu" }
# ///
"""Converts a Marian translation model from Hugging Face into the two int8
ONNX graphs the app's translator runs, and prints the sha256 and size of
all six files a catalog entry pins.

This is the recipe ADR-0014's "converted by Trellis" rung requires: the
exact steps and pinned versions, so anyone can make the same files again.
docs/how-to/convert-a-translation-model.md explains how to use it.

Usage (from app/):
    tool/convert_marian_onnx.py <model id> <upstream commit> <out dir>
Example:
    tool/convert_marian_onnx.py Mitsua/elan-mt-bt-en-ja \\
        02c48e7031386cd2d41974b0ff1aaf52f010c5fa ../../elan-onnx

Newer optimum (2.x) and torch (2.9 and later) failed to export these
models when this was written; keep the pins.
"""

import hashlib
import os
import sys

from huggingface_hub import snapshot_download
from onnxruntime.quantization import QuantType, quantize_dynamic
from optimum.exporters.onnx import main_export

# The four small files the catalog fetches straight from the upstream
# commit, unchanged, in the catalog's layout order after the two graphs.
UPSTREAM_FILES = ("source.spm", "vocab.json", "config.json", "tokenizer_config.json")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    model_id, revision, out = sys.argv[1], sys.argv[2], sys.argv[3]
    if len(revision) != 40:
        sys.exit("name the upstream commit in full (40 hex characters), never a branch")
    os.makedirs(out, exist_ok=True)

    upstream = snapshot_download(model_id, revision=revision)
    main_export(upstream, output=out, task="text2text-generation-with-past", opset=14)

    # Dynamic int8, one scale per tensor. The merged decoder keeps its two
    # branches inside If nodes: without EnableSubgraph they stay fp32 and
    # the file stays about four times as big.
    quantize_dynamic(
        os.path.join(out, "encoder_model.onnx"),
        os.path.join(out, "encoder_model_quantized.onnx"),
        weight_type=QuantType.QInt8,
        per_channel=False,
    )
    quantize_dynamic(
        os.path.join(out, "decoder_model_merged.onnx"),
        os.path.join(out, "decoder_model_merged_quantized.onnx"),
        weight_type=QuantType.QInt8,
        per_channel=False,
        extra_options={"EnableSubgraph": True},
    )

    rows = [os.path.join(out, "encoder_model_quantized.onnx"),
            os.path.join(out, "decoder_model_merged_quantized.onnx")]
    rows += [os.path.join(upstream, name) for name in UPSTREAM_FILES]
    total = 0
    print("file, bytes, sha256 (catalog layout order)")
    for path in rows:
        size = os.path.getsize(path)
        total += size
        print(f"{os.path.basename(path)} {size} {sha256(path)}")
    print(f"total {total}")


if __name__ == "__main__":
    main()
