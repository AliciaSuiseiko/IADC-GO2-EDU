#!/usr/bin/env python3
"""Lightweight OSNet identity features for the panoramic SOT adapter."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import cv2
import numpy as np
import torch


class OSNetIdentityEncoder:
    def __init__(self, repo: Path, checkpoint: Path, device: str = "cuda") -> None:
        self.device = torch.device(device)
        model_path = repo / "torchreid" / "models" / "osnet_ain.py"
        spec = importlib.util.spec_from_file_location("panorama_osnet_ain", model_path)
        if spec is None or spec.loader is None:
            raise ImportError(f"Cannot load OSNet model definition from {model_path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.model = module.osnet_ain_x1_0(
            num_classes=1000,
            loss="softmax",
            pretrained=False,
            use_gpu=self.device.type == "cuda",
        )
        payload = torch.load(str(checkpoint), map_location="cpu")
        state_dict = payload.get("state_dict", payload)
        model_dict = self.model.state_dict()
        matched = {}
        for key, value in state_dict.items():
            key = key.removeprefix("module.")
            if key in model_dict and model_dict[key].shape == value.shape:
                matched[key] = value
        if not matched:
            raise RuntimeError(f"No compatible OSNet weights found in {checkpoint}")
        model_dict.update(matched)
        self.model.load_state_dict(model_dict)
        self.model.to(self.device).eval()
        self.mean = torch.tensor([0.485, 0.456, 0.406], device=self.device).view(1, 3, 1, 1)
        self.std = torch.tensor([0.229, 0.224, 0.225], device=self.device).view(1, 3, 1, 1)

    def encode(self, crops_bgr: list[np.ndarray]) -> np.ndarray:
        valid = []
        for crop in crops_bgr:
            if crop is None or crop.size == 0:
                raise ValueError("Identity crop is empty")
            rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)
            rgb = cv2.resize(rgb, (128, 256), interpolation=cv2.INTER_LINEAR)
            valid.append(torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0)
        batch = torch.stack(valid).to(self.device)
        batch = (batch - self.mean) / self.std
        with torch.no_grad():
            features = self.model(batch)
        features = torch.nn.functional.normalize(features, dim=1)
        return features.cpu().numpy()


def cosine_similarity(first: np.ndarray, second: np.ndarray) -> float:
    first = first.reshape(-1)
    second = second.reshape(-1)
    denominator = np.linalg.norm(first) * np.linalg.norm(second)
    return float(np.dot(first, second) / denominator) if denominator > 0.0 else -1.0


def crop_box(image: np.ndarray, bbox_xywh, padding: float = 0.05) -> np.ndarray:
    x, y, width, height = [float(value) for value in bbox_xywh]
    x -= width * padding
    y -= height * padding
    width *= 1.0 + 2.0 * padding
    height *= 1.0 + 2.0 * padding
    x1 = max(0, int(round(x)))
    y1 = max(0, int(round(y)))
    x2 = min(image.shape[1], int(round(x + width)))
    y2 = min(image.shape[0], int(round(y + height)))
    return image[y1:y2, x1:x2]
