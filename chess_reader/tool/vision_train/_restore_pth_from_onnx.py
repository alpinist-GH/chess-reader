"""Rebuild a .pth checkpoint from an ONNX export whose BatchNorm layers were
fused into the preceding Conv at export time (eval-mode ONNX export folds
Conv+BN into one Conv). The resulting torch model is functionally identical
to the ONNX graph (BatchNorm set to identity), safe to use as a warm-start.
"""
import sys

import onnx
import torch

from cls2_model import SquareCNN2

onnx_path, out_path = sys.argv[1], sys.argv[2]
m = onnx.load(onnx_path)
init = {i.name: torch.from_numpy(onnx.numpy_helper.to_array(i)).clone() for i in m.graph.initializer}

model = SquareCNN2()
sd = model.state_dict()

sd['features.0.weight'] = init['onnx::Conv_43']
sd['features.0.bias'] = init['onnx::Conv_44']
sd['features.4.weight'] = init['onnx::Conv_46']
sd['features.4.bias'] = init['onnx::Conv_47']
sd['features.8.weight'] = init['onnx::Conv_49']
sd['features.8.bias'] = init['onnx::Conv_50']

for bn, ch in [('features.1', 16), ('features.5', 32), ('features.9', 64)]:
    sd[f'{bn}.weight'] = torch.ones(ch)
    sd[f'{bn}.bias'] = torch.zeros(ch)
    sd[f'{bn}.running_mean'] = torch.zeros(ch)
    sd[f'{bn}.running_var'] = torch.ones(ch)
    sd[f'{bn}.num_batches_tracked'] = torch.tensor(0)

sd['classifier.1.weight'] = init['classifier.1.weight']
sd['classifier.1.bias'] = init['classifier.1.bias']
sd['classifier.4.weight'] = init['classifier.4.weight']
sd['classifier.4.bias'] = init['classifier.4.bias']

model.load_state_dict(sd)
torch.save(model.state_dict(), out_path)
print('saved', out_path)
