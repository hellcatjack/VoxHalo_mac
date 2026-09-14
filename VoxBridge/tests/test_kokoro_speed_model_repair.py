import pytest
import os
import sys

onnx = pytest.importorskip('onnx')  # Optional, isolated asset-repair tool dependency.
from tools.repair_kokoro_speed import main, repair_model


def model_file(tmp_path, *, consumer_type=onnx.TensorProto.FLOAT):
    h = onnx.helper
    graph = h.make_graph([h.make_node('Cast', ['speed'], ['out'], to=consumer_type)], 'speed',
        [h.make_tensor_value_info('speed', onnx.TensorProto.INT32, [1])],
        [h.make_tensor_value_info('out', consumer_type, [1])],
        [h.make_tensor('unchanged_weight', onnx.TensorProto.FLOAT, [2], [0.3, 0.7])])
    source = tmp_path/'original.onnx'
    onnx.save(h.make_model(graph), source)
    return source


def test_repair_changes_only_input_type_and_preserves_source(tmp_path):
    source = model_file(tmp_path); before = source.read_bytes(); destination = tmp_path/'fixed.onnx'
    result = repair_model(source, destination)
    assert source.read_bytes() == before
    model = onnx.load(destination)
    assert model.graph.input[0].type.tensor_type.elem_type == onnx.TensorProto.FLOAT
    model.graph.input[0].type.tensor_type.elem_type = onnx.TensorProto.INT32
    assert model.SerializeToString() == onnx.load(source).SerializeToString()
    assert result['weights_unchanged'] and result['only_speed_input_type_changed']
    with pytest.raises(FileExistsError): repair_model(source, destination)
    with pytest.raises(ValueError): repair_model(source, source)


def test_repair_refuses_graph_that_would_discard_fractional_speed(tmp_path):
    source = model_file(tmp_path, consumer_type=onnx.TensorProto.INT32)
    with pytest.raises(ValueError, match='Cast.*FLOAT'):
        repair_model(source, tmp_path/'bad.onnx')
    assert not (tmp_path/'bad.onnx').exists()


@pytest.mark.parametrize('target', ['source', 'destination', 'source_symlink',
                                  'destination_symlink', 'source_hardlink', 'existing'])
def test_report_cannot_overwrite_models_or_existing_files(tmp_path, monkeypatch, target):
    source = model_file(tmp_path)
    before = source.read_bytes()
    destination, report = tmp_path/'fixed.onnx', tmp_path/'report.json'
    if target == 'source': report = source
    elif target == 'destination': report = destination
    elif target == 'source_symlink': report.symlink_to(source)
    elif target == 'destination_symlink': report.symlink_to(destination)
    elif target == 'source_hardlink': os.link(source, report)
    else: report.write_text('keep this report')
    monkeypatch.setattr(sys, 'argv', ['repair', str(source), str(destination), '--report', str(report)])
    with pytest.raises((ValueError, FileExistsError)):
        main()
    assert source.read_bytes() == before
    assert not destination.exists()
    if target == 'existing': assert report.read_text() == 'keep this report'
