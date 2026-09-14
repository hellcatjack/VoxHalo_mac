"""Create a separate float-speed Kokoro graph without changing weights or nodes.

One-time tool: requires onnx in an isolated tool path, not in the service runtime.
The original model and any existing destination are never overwritten.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile


def publish_new_file(destination: Path, data: bytes) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.kokoro-speed-', delete=False) as out:
        temporary = Path(out.name)
        try:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
            os.link(temporary, destination)  # Atomic publish, refuses existing files.
        finally:
            temporary.unlink(missing_ok=True)


def repair_model(source: Path, destination: Path) -> dict:
    import onnx
    source, destination = source.resolve(), destination.absolute()
    if source == destination.resolve():
        raise ValueError('Source and destination must be different.')
    if os.path.lexists(destination):
        raise FileExistsError(destination)
    model = onnx.load(source, load_external_data=False)
    if any(t.external_data for t in model.graph.initializer):
        raise ValueError('External model tensors are not supported by this repair.')
    inputs = [x for x in model.graph.input if x.name == 'speed']
    if len(inputs) != 1 or inputs[0].type.tensor_type.elem_type != onnx.TensorProto.INT32:
        raise ValueError('Expected exactly one int32 speed input.')
    consumers = [n for n in model.graph.node if 'speed' in n.input]
    if not consumers or any(n.op_type != 'Cast' or not any(
            a.name == 'to' and a.i == onnx.TensorProto.FLOAT for a in n.attribute) for n in consumers):
        raise ValueError('Every speed consumer must Cast directly to FLOAT.')
    before = model.SerializeToString()
    inputs[0].type.tensor_type.elem_type = onnx.TensorProto.FLOAT
    onnx.checker.check_model(model)
    repaired = model.SerializeToString()
    # Prove the entire serialized graph is unchanged after undoing this one field.
    inputs[0].type.tensor_type.elem_type = onnx.TensorProto.INT32
    if model.SerializeToString() != before:
        raise ValueError('Unexpected model mutation.')
    publish_new_file(destination, repaired)
    return {'source': str(source), 'destination': str(destination),
            'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'destination_sha256': hashlib.sha256(repaired).hexdigest(),
            'weights_unchanged': True, 'only_speed_input_type_changed': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.report:
        if args.report.resolve() in {args.source.resolve(), args.destination.resolve()}:
            raise ValueError('Report must be separate from both model assets.')
        if os.path.lexists(args.report):
            raise FileExistsError(args.report)
    report = json.dumps(repair_model(args.source, args.destination), indent=2)
    if args.report:
        publish_new_file(args.report, (report + '\n').encode())
    print(report)


if __name__ == '__main__':
    main()
