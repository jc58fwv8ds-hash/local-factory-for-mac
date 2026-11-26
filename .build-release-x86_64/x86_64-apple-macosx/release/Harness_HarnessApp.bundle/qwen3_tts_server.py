import contextlib
import json
import os
import sys

# The resident speaker (2026-10-19, roadmap V2): the model is loaded once and each request, one JSON line on stdin, is
# spoken in pieces. Each piece is written as a WAV inside the request's own private folder and announced on stdout as soon
# as it exists, so playback can start about 1.4 s after the request instead of re-loading the model every sentence.
# Network access is off (HF_HUB_OFFLINE) and paths outside the request folder are refused.

MAX_TEXT_CHARACTERS = 1200


def inside(folder, path):
    folder = os.path.realpath(folder)
    path = os.path.realpath(path)
    return os.path.commonpath((folder, path)) == folder


def say(payload):
    sys.__stdout__.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.__stdout__.flush()


def main():
    model_path = os.path.realpath(sys.argv[sys.argv.index("--model") + 1])
    if not os.path.isdir(model_path):
        raise ValueError("model missing")
    with open(os.devnull, "w", encoding="utf-8") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        from mlx_audio.audio_io import write as audio_write
        from mlx_audio.tts.utils import load_model
        import numpy as np
        model = load_model(model_path)
    say({"status": "ready"})
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            folder = request["folder"]
            text = request["text"].strip()
            reference_text = request["referenceText"].strip()
            reference_audio = request["referenceAudioPath"]
            if not text or len(text) > MAX_TEXT_CHARACTERS or not reference_text:
                raise ValueError("invalid text")
            if not inside(folder, reference_audio) or not os.path.isfile(reference_audio):
                raise ValueError("reference outside request folder")
            index = 0
            with open(os.devnull, "w", encoding="utf-8") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                for piece in model.generate(text=text, language=request.get("language", "Auto"), ref_audio=reference_audio,
                                            ref_text=reference_text, verbose=False, stream=True):
                    path = os.path.join(folder, f"piece-{index:03d}.wav")
                    audio_write(path, np.array(piece.audio), getattr(piece, "sample_rate", model.sample_rate))
                    say({"id": request["id"], "piece": index, "path": path})
                    index += 1
            say({"id": request["id"], "status": "done", "pieces": index})
        except Exception as error:
            say({"id": request.get("id"), "status": "failed", "reason": type(error).__name__})


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        say({"status": "failed", "reason": type(error).__name__})
        sys.exit(1)
