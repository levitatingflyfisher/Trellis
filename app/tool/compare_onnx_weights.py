#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["onnx==1.17.0"]
# ///
"""Says whether two ONNX files carry the same weights and the same graph
shape, ignoring the names the exporter makes up for its nodes.

A re-run of convert_marian_onnx.py gives the encoder byte for byte, but
the merged decoder's internal names come out numbered differently, so its
sha256 differs. This is how to check that a re-run made the same model.

Usage: tool/compare_onnx_weights.py <a.onnx> <b.onnx>
Exits 0 when the weights and op sequence match, 1 when they don't.
"""

import hashlib
import sys

import onnx
from onnx import numpy_helper


def walk(graph, weights, ops):
    for t in graph.initializer:
        weights.append(hashlib.sha256(numpy_helper.to_array(t).tobytes()).hexdigest())
    for n in graph.node:
        ops.append((n.op_type, len(n.input), len(n.output)))
        for a in n.attribute:
            if a.type == onnx.AttributeProto.GRAPH:
                walk(a.g, weights, ops)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    found = []
    for path in sys.argv[1:]:
        weights, ops = [], []
        walk(onnx.load(path).graph, weights, ops)
        found.append((sorted(weights), ops))
    same_weights = found[0][0] == found[1][0]
    same_ops = found[0][1] == found[1][1]
    print(f"weights: {len(found[0][0])} vs {len(found[1][0])}, same: {same_weights}")
    print(f"ops in order: {len(found[0][1])} vs {len(found[1][1])}, same: {same_ops}")
    sys.exit(0 if same_weights and same_ops else 1)


if __name__ == "__main__":
    main()
