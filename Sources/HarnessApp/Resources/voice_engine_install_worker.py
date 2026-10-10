import argparse
import hashlib
import json
import os
import sys


MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16"
MODEL_REVISION = "1eccf1cb2519b5a4e8a95b5f0544f3303568164f"
EXPECTED_FILES = {
    "model.safetensors": (
        1829344448,
        "d7c7ed3e3464e3e59de0f955b3755891fa8319ff061c3f0307fe2e1343bc122d",
    ),
    "speech_tokenizer/model.safetensors": (
        682293092,
        "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258",
    ),
}


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

    emit("downloadingModel", "約2.52GBの音声モデルを取得しています")
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
    arguments = parser.parse_args()
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
