#!/usr/bin/env python3
import runpy
import sys

import torch


def _torch24_custom_fwd(*args, **kwargs):
    kwargs.pop("device_type", None)
    return torch.cuda.amp.custom_fwd(*args, **kwargs)


def _torch24_custom_bwd(bwd=None, *args, **kwargs):
    kwargs.pop("device_type", None)
    if bwd is None:
        return lambda function: torch.cuda.amp.custom_bwd(function)
    return torch.cuda.amp.custom_bwd(bwd)


if not hasattr(torch.amp, "custom_fwd"):
    torch.amp.custom_fwd = _torch24_custom_fwd
if not hasattr(torch.amp, "custom_bwd"):
    torch.amp.custom_bwd = _torch24_custom_bwd

if len(sys.argv) < 2:
    raise SystemExit("usage: dap_torch24_compat_infer.py /path/to/test/infer.py [args...]")

entrypoint = sys.argv.pop(1)
sys.argv[0] = entrypoint
runpy.run_path(entrypoint, run_name="__main__")
