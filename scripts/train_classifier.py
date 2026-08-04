#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
import json
import math
import os
import random
import sys
import tempfile
from pathlib import Path

try:
    import torch
    from torch import nn
except Exception as exc:
    print(json.dumps({
        "status": "error",
        "message": f"PyTorch is not available for this Python: {exc}",
    }))
    sys.exit(2)


CHANNELS = ["TP9", "AF7", "AF8", "TP10"]
FEATURES = ["mean", "std", "min", "max", "rms", "ptp"]
CLASSES = ["Y", "N", "P", "T"]
WINDOW_START_BEFORE_S = 2.5
WINDOW_END_BEFORE_S = 0.5
MIN_SAMPLES_PER_CHANNEL = 8
SEED = 1729


def parse_time(value):
    value = (value or "").strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return dt.datetime.fromisoformat(value).timestamp()


def normalize_label(row):
    label = (row.get("label") or "").strip().lower()
    kind = (row.get("type") or "").strip().lower()
    if kind == "yes" or label == "yes":
        return "Y"
    if kind == "no" or label == "no":
        return "N"
    if kind == "allow_permission" or label == "allow permission":
        return "P"
    if kind.startswith("talk") or label.startswith("talk"):
        return "T"
    return None


def find_sessions(root):
    root = Path(root).expanduser()
    if not root.exists():
        return []
    sessions = []
    for current_root, _, files in os.walk(root):
        file_set = set(files)
        if "muse-eeg.csv" in file_set and "annotations.csv" in file_set:
            sessions.append(Path(current_root))
    return sorted(sessions)


def channel_features(values):
    count = len(values)
    mean = sum(values) / count
    variance = sum((value - mean) ** 2 for value in values) / count
    std = math.sqrt(variance)
    min_value = min(values)
    max_value = max(values)
    rms = math.sqrt(sum(value * value for value in values) / count)
    return [mean, std, min_value, max_value, rms, max_value - min_value]


def load_session_examples(session_dir):
    muse_path = session_dir / "muse-eeg.csv"
    annotations_path = session_dir / "annotations.csv"
    samples_by_channel = {channel: [] for channel in CHANNELS}

    with muse_path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            channel = row.get("channel")
            if channel not in samples_by_channel:
                continue
            try:
                timestamp = parse_time(row.get("sample_timestamp_utc"))
                value = float(row.get("value_uv"))
            except Exception:
                continue
            samples_by_channel[channel].append((timestamp, value))

    for channel in CHANNELS:
        samples_by_channel[channel].sort(key=lambda item: item[0])

    examples = []
    with annotations_path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            label = normalize_label(row)
            if label is None:
                continue
            try:
                event_time = parse_time(row.get("timestamp_utc"))
            except Exception:
                continue

            window_start = event_time - WINDOW_START_BEFORE_S
            window_end = event_time - WINDOW_END_BEFORE_S
            features = []
            usable = True
            for channel in CHANNELS:
                values = [
                    value
                    for timestamp, value in samples_by_channel[channel]
                    if window_start <= timestamp <= window_end
                ]
                if len(values) < MIN_SAMPLES_PER_CHANNEL:
                    usable = False
                    break
                features.extend(channel_features(values))
            if usable:
                examples.append((features, CLASSES.index(label), session_dir.name))

    return examples


def load_examples(root):
    examples = []
    for session_dir in find_sessions(root):
        examples.extend(load_session_examples(session_dir))
    return examples


class MLP(nn.Module):
    def __init__(self, input_size, hidden_size=32, output_size=4):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(input_size, hidden_size),
            nn.ReLU(),
            nn.Linear(hidden_size, output_size),
        )

    def forward(self, x):
        return self.net(x)


def split_examples(examples):
    indices = list(range(len(examples)))
    random.Random(SEED).shuffle(indices)
    test_count = max(1, int(round(len(indices) * 0.2)))
    if len(indices) - test_count < 1:
        test_count = 1
    test_indices = indices[:test_count]
    train_indices = indices[test_count:]
    return train_indices, test_indices


def train_model(examples):
    torch.manual_seed(SEED)
    random.seed(SEED)

    vectors = torch.tensor([example[0] for example in examples], dtype=torch.float32)
    labels = torch.tensor([example[1] for example in examples], dtype=torch.long)
    mean = vectors.mean(dim=0)
    std = vectors.std(dim=0, unbiased=False).clamp_min(1e-6)
    normalized = (vectors - mean) / std

    train_indices, test_indices = split_examples(examples)
    model = MLP(normalized.shape[1])
    optimizer = torch.optim.Adam(model.parameters(), lr=0.01, weight_decay=1e-4)
    loss_fn = nn.CrossEntropyLoss()

    train_x = normalized[train_indices]
    train_y = labels[train_indices]
    for _ in range(300):
        model.train()
        optimizer.zero_grad()
        loss = loss_fn(model(train_x), train_y)
        loss.backward()
        optimizer.step()

    model.eval()
    with torch.no_grad():
        logits = model(normalized[test_indices])
        predictions = logits.argmax(dim=1)
        accuracy = (predictions == labels[test_indices]).float().mean().item()

    return model, mean, std, accuracy, train_indices, test_indices


def model_to_json(model, mean, std, accuracy, examples, train_indices, test_indices):
    first = model.net[0]
    second = model.net[2]
    labels = [example[1] for example in examples]
    class_counts = {name: labels.count(index) for index, name in enumerate(CLASSES)}
    return {
        "format_version": 1,
        "model_type": "mlp",
        "classes": CLASSES,
        "channels": CHANNELS,
        "features": FEATURES,
        "window": {
            "start_before_seconds": WINDOW_START_BEFORE_S,
            "end_before_seconds": WINDOW_END_BEFORE_S,
            "min_samples_per_channel": MIN_SAMPLES_PER_CHANNEL,
        },
        "input_mean": mean.tolist(),
        "input_std": std.tolist(),
        "layers": [
            {
                "weight": first.weight.detach().tolist(),
                "bias": first.bias.detach().tolist(),
                "activation": "relu",
            },
            {
                "weight": second.weight.detach().tolist(),
                "bias": second.bias.detach().tolist(),
                "activation": "linear",
            },
        ],
        "test_accuracy": accuracy,
        "num_examples": len(examples),
        "num_train_examples": len(train_indices),
        "num_test_examples": len(test_indices),
        "class_counts": class_counts,
        "trained_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def existing_accuracy(path):
    try:
        with Path(path).open() as handle:
            payload = json.load(handle)
        return float(payload.get("test_accuracy"))
    except Exception:
        return None


def atomic_write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), suffix=".tmp") as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.write("\n")
        tmp_path = handle.name
    os.replace(tmp_path, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--model-path", required=True)
    args = parser.parse_args()

    examples = load_examples(args.data_root)
    labels = {example[1] for example in examples}
    if len(examples) < 4 or len(labels) < 2:
        print(json.dumps({
            "status": "error",
            "message": "Need at least 4 usable annotated EEG windows across at least 2 classes.",
            "num_examples": len(examples),
            "num_classes": len(labels),
        }))
        return 1

    model, mean, std, accuracy, train_indices, test_indices = train_model(examples)
    payload = model_to_json(model, mean, std, accuracy, examples, train_indices, test_indices)
    old_accuracy = existing_accuracy(args.model_path)
    should_keep = old_accuracy is None or accuracy > old_accuracy
    if should_keep:
        atomic_write_json(args.model_path, payload)

    print(json.dumps({
        "status": "kept" if should_keep else "discarded",
        "message": "Kept new model." if should_keep else "Existing model test accuracy is better or equal.",
        "test_accuracy": accuracy,
        "old_test_accuracy": old_accuracy,
        "num_examples": len(examples),
        "num_train_examples": len(train_indices),
        "num_test_examples": len(test_indices),
        "class_counts": payload["class_counts"],
        "model_path": str(args.model_path),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
