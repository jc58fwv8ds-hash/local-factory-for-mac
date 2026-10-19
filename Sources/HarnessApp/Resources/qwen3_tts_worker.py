import argparse
import contextlib
import io
import json
import os
import sys


ENGINE_IDS = {"qwen3-tts.mlx.0.6b-base", "qwen3-tts.mlx.1.7b-base"}
MAX_TEXT_CHARACTERS = 1200


def require_private_request(path):
    absolute = os.path.realpath(path)
    if not os.path.isabs(absolute) or not os.path.isfile(absolute):
        raise ValueError("invalid request")
    with open(absolute, "r", encoding="utf-8") as handle:
        request = json.load(handle)
    if request.get("schemaVersion") != 1:
        raise ValueError("unsupported request")
    if request.get("engineIdentifier") not in ENGINE_IDS:
        raise ValueError("wrong engine")
    return absolute, request


def read_text(path, maximum):
    with open(path, "r", encoding="utf-8") as handle:
        value = handle.read(maximum + 1).strip()
    if not value or len(value) > maximum:
        raise ValueError("invalid text")
    return value


def validate_paths(request_path, request):
    request_root = os.path.dirname(request_path)
    for key in ("textPath", "referenceAudioPath", "referenceTextPath", "outputPath"):
        candidate = os.path.realpath(request[key])
        if os.path.commonpath((request_root, candidate)) != request_root:
            raise ValueError("path escaped request root")
    model_path = os.path.realpath(request["modelPath"])
    if not os.path.isdir(model_path):
        raise ValueError("model missing")


def generate(request):
    text = read_text(request["textPath"], MAX_TEXT_CHARACTERS)
    reference_text = read_text(request["referenceTextPath"], 4000)
    if not os.path.isfile(request["referenceAudioPath"]):
        raise ValueError("reference missing")
    from mlx_audio.audio_io import write as audio_write
    from mlx_audio.tts.utils import load_model

    with open(os.devnull, "w", encoding="utf-8") as sink:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            model = load_model(request["modelPath"])
            result = next(model.generate(
                text=text,
                language=request["language"],
                ref_audio=request["referenceAudioPath"],
                ref_text=reference_text,
                verbose=False,
                stream=False,
            ))
            sample_rate = getattr(result, "sample_rate", model.sample_rate)
            audio_write(request["outputPath"], result.audio, sample_rate)
    return sample_rate


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--request", required=True)
    arguments = parser.parse_args()
    request_path, request = require_private_request(arguments.request)
    validate_paths(request_path, request)
    sample_rate = generate(request)
    print(json.dumps({"status": "ok", "sampleRate": sample_rate}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(json.dumps({"status": "failed"}))
        sys.exit(1)
