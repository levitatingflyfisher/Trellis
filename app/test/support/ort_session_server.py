#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["onnxruntime==1.20.1", "numpy==1.26.4"]
# ///
"""Runs ONNX sessions for a Dart test over stdin and stdout, one JSON
object per line, so a host test can drive the app's own Marian generation
loop against real graphs. flutter_onnxruntime talks to the phone's
runtime over a platform channel, which `flutter test` does not have.

Usage: ort_session_server.py name=path.onnx [name=path.onnx ...]

Requests:
  {"op": "run", "session": name, "feeds": {...}, "fetch": [names] | null}
  {"op": "release", "handles": [ids]}
  {"op": "live"}
A feed is {"handle": id} or {"dtype", "shape", "b64"} (little-endian
bytes). An output named in "fetch" (or every output, when "fetch" is
null) comes back as data; any other stays here as a handle, the way the
app's runner leaves tensors on the runtime's side.
"""

import base64
import json
import sys

import numpy as np
import onnxruntime as ort

DTYPES = {"int64": np.int64, "float32": np.float32, "boolean": np.bool_}


def name_of(array):
    if array.dtype == np.bool_:
        return "boolean"
    if array.dtype in (np.int64, np.int32):
        return "int64"
    return "float32"


def main():
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 2
    sessions = {}
    for arg in sys.argv[1:]:
        name, path = arg.split("=", 1)
        sessions[name] = ort.InferenceSession(
            path, opts, providers=["CPUExecutionProvider"])
    handles = {}
    next_id = 0
    print(json.dumps({"ready": True, "ort": ort.__version__}), flush=True)
    for line in sys.stdin:
        req = json.loads(line)
        op = req["op"]
        if op == "live":
            print(json.dumps({"live": len(handles)}), flush=True)
            continue
        if op == "release":
            for h in req["handles"]:
                handles.pop(h, None)
            print(json.dumps({"ok": True}), flush=True)
            continue
        session = sessions[req["session"]]
        feeds = {}
        for key, value in req["feeds"].items():
            if "handle" in value:
                feeds[key] = handles[value["handle"]]
            else:
                raw = base64.b64decode(value["b64"])
                feeds[key] = np.frombuffer(raw, dtype=DTYPES[value["dtype"]]).reshape(
                    value["shape"])
        names = [o.name for o in session.get_outputs()]
        results = session.run(names, feeds)
        fetch = req.get("fetch")
        outputs = {}
        for key, array in zip(names, results):
            array = np.ascontiguousarray(array)
            if array.dtype == np.int32:
                array = array.astype(np.int64)
            if fetch is None or key in fetch:
                outputs[key] = {
                    "dtype": name_of(array),
                    "shape": list(array.shape),
                    "b64": base64.b64encode(array.tobytes()).decode("ascii"),
                }
            else:
                handles[next_id] = array
                outputs[key] = {"handle": next_id, "dtype": name_of(array),
                                "shape": list(array.shape)}
                next_id += 1
        print(json.dumps({"outputs": outputs}), flush=True)


if __name__ == "__main__":
    main()
