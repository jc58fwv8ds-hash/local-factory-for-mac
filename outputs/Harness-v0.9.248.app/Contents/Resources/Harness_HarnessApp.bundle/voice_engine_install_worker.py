import argparse
import hashlib
import json
import os
import sys


# The model, its pinned revision and the exact weight files come from the app (Qwen3TTSModelVariant), so one worker
# installs any variant the app knows; nothing is downloaded without a revision and every listed file is hash-checked.
MODEL_ID = None
MODEL_REVISION = None
EXPECTED_FILES = {}


def emit(phase, status, fraction=None):
    payload = {"phase": phase, "status": status}
    if fraction is not None:
        payload["fraction"] = fraction
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_model(model_root):
    for index, (relative_path, expected) in enumerate(EXPECTED_FILES.items()):
        path = os.path.realpath(os.path.join(model_root, relative_path))
        if os.path.commonpath((model_root, path)) != model_root:
            raise ValueError("model path escaped root")
        expected_size, expected_hash = expected
        if not os.path.isfile(path) or os.path.getsize(path) != expected_size:
            raise ValueError("model size mismatch")
        emit("verifying", "モデル内容を検証しています", index / len(EXPECTED_FILES))
        if hash_file(path) != expected_hash:
            raise ValueError("model hash mismatch")
    required = ["config.json", "model.safetensors.index.json"]
    if not all(os.path.isfile(os.path.join(model_root, item)) for item in required):
        raise ValueError("model metadata missing")
    emit("verifying", "モデル内容を検証しました", 1.0)


def download(model_root, cache_root):
    from huggingface_hub import snapshot_download

    emit("downloadingModel", "音声モデルを取得しています")
    snapshot_download(
        repo_id=MODEL_ID,
        revision=MODEL_REVISION,
        local_dir=model_root,
        cache_dir=cache_root,
    )


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--model-root", required=True)
    parser.add_argument("--cache-root", required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--expected", required=True)
    arguments = parser.parse_args()
    global MODEL_ID, MODEL_REVISION, EXPECTED_FILES
    if not arguments.model_id.startswith("mlx-community/Qwen3-TTS-") or len(arguments.revision) != 40:
        raise ValueError("unexpected model")
    MODEL_ID = arguments.model_id
    MODEL_REVISION = arguments.revision
    EXPECTED_FILES = {item["path"]: (int(item["bytes"]), item["sha256"]) for item in json.loads(arguments.expected)}
    if not EXPECTED_FILES:
        raise ValueError("no expected files")
    model_root = os.path.realpath(arguments.model_root)
    cache_root = os.path.realpath(arguments.cache_root)
    os.makedirs(model_root, mode=0o700, exist_ok=True)
    os.makedirs(cache_root, mode=0o700, exist_ok=True)
    download(model_root, cache_root)
    verify_model(model_root)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        print(json.dumps({"phase": "failed", "status": type(error).__name__}))
        sys.exit(1)
