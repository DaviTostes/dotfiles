#!/usr/bin/env python3
# Real-time full-duplex voice conversation daemon for OpenCode (Quickshell).
#
# Combines:
#   1. Continuous 16kHz mic capture (pw-record) + adaptive VAD + barge-in
#   2. Warm whisper-server (ggml-small.bin) with dynamic per-clip audio_ctx
#      (~250ms transcription latency; automatic fallback to whisper-cli)
#   3. Warm neural TTS via calibre_extensions.piper (pt_BR-faber-medium +
#      en_US-lessac-medium at 22050Hz, ~100ms synthesis; fallback to espeak-ng)
#   4. Two-stage synthesis -> playback pipeline over pw-cat for zero-gap
#      sentence streaming and instant (<30ms) barge-in interruption.
#
# Protocol: JSON-lines over stdin (commands) and stdout (events).

import array
import atexit
import collections
import ctypes
import json
import math
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import wave
from typing import NamedTuple

try:
    import numpy as np
except ImportError:
    np = None  # type: ignore

# Ensure child processes (whisper-server, pw-record, pw-cat) receive SIGTERM
# immediately from the kernel if this daemon exits or is killed.
try:
    _libc = ctypes.CDLL("libc.so.6", use_errno=True)
except Exception:
    _libc = None


def _child_preexec() -> None:
    if _libc is not None:
        try:
            _libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG = 1
        except Exception:
            pass


# ---- constants --------------------------------------------------------------
MIC_RATE = 16000
FRAME_SAMPLES = 512                      # 32ms per frame at 16kHz
FRAME_BYTES = FRAME_SAMPLES * 2          # s16le mono
PREROLL_FRAMES = 15                      # ~480ms pre-roll before speech onset
START_FRAMES = 3                         # ~96ms above threshold to start speech
BARGE_FRAMES = 7                         # ~224ms sustained speech to interrupt TTS
SILENCE_FRAMES = 44                      # ~1.40s natural pause to finalize turn
MIN_SPEECH_FRAMES = 10                   # ~320ms minimum valid speech
MAX_SPEECH_FRAMES = 1875                 # ~60s maximum single utterance
TTS_RATE = 22050
TTS_CHUNK_SAMPLES = 882                  # 40ms per UI/envelope slice at 22050Hz
TTS_CHUNK_BYTES = TTS_CHUNK_SAMPLES * 2
# pw-cat uses glibc fread(stdin) with 4096-byte blocks inside PipeWire's
# real-time on_process callback. Writing in 4096-byte aligned blocks with a
# ~320ms pre-buffer lead guarantees fread never blocks inside on_process.
PIPE_BLOCK_BYTES = 4096
PIPE_PREBUFFER_S = 0.32

HOME = os.path.expanduser("~")
WHISPER_DIR = os.path.join(HOME, ".local/share/whisper")
# Two quality levels instead of one: `small` is ~1 s per utterance, `medium-q5`
# roughly halves the word error rate on mixed PT/EN speech at ~3.7 s. Override
# either with OPENCODE_VOICE_WHISPER_MODEL / _MODEL_ACCURATE.
WHISPER_MODELS = {
    "fast": os.environ.get("OPENCODE_VOICE_WHISPER_MODEL")
        or os.path.join(WHISPER_DIR, "ggml-small.bin"),
    "accurate": os.environ.get("OPENCODE_VOICE_WHISPER_MODEL_ACCURATE")
        or os.path.join(WHISPER_DIR, "ggml-medium-q5_0.bin"),
}
# legacy alias: the CLI fallback resolves its model through self.model_path()
WHISPER_MODEL = WHISPER_MODELS["fast"]
PIPER_DIR = os.path.join(HOME, ".local/share/piper")
VOICES = {
    "pt": os.path.join(PIPER_DIR, "pt_BR-faber-medium.onnx"),
    "en": os.path.join(PIPER_DIR, "en_US-lessac-medium.onnx"),
}

# Whisper silence hallucinations to ignore
HALLUCINATIONS = {
    "", "you", "thank you", "thank you.", "thanks for watching!",
    "thanks for watching.", "obrigado por assistir", "obrigado por assistir.",
    "obrigado.", "legendas pela comunidade", "subtitles by", "amara.org",
    "música", "musica", "música de fundo", "aplausos", "risos", "silêncio",
}
HALLUCINATION_RE = re.compile(
    r"^(\s*(\[[^\]]*\]|\([^\)]*\)|\*[^\*]*\*|♪+|[.,!?;:…-])+)+\s*$",
    re.IGNORECASE,
)

out_lock = threading.Lock()


def emit(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False)
    with out_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)


# Terms a Brazilian dev mixes into spoken Portuguese. Whisper's decoder is
# primed with this list as its `initial_prompt` (whisper-server takes it ONLY as
# a startup option — `--prompt`; it is NOT a multipart form field, so it cannot
# be changed per request), without which a Brazilian accent turns "commit" into
# "permite", "branch" into "tranche" and "deploy" into "etoy".
TECH_TERMS = (
    "commit", "branch", "feature", "build", "deploy", "rollback", "merge",
    "rebase", "push", "pull", "issue", "bug", "fix", "patch", "timeout",
    "request", "response", "cache", "render", "frontend", "backend",
    "endpoint", "container", "docker", "script", "server", "client",
    "database", "query", "index", "component", "state", "hook", "refactor",
    "review", "pipeline", "main", "master", "hotfix", "release", "clone",
    "fork", "stash", "diff", "terminal", "shell", "runtime", "thread",
    "queue", "buffer", "stack", "trace", "config", "setup", "lint", "grep",
    "regex", "checkout", "worktree", "monorepo", "websocket", "token",
    "socket", "daemon", "cron", "upload", "download", "layout", "widget",
    "callback", "async", "preview", "mock", "staging",
)
TERM_SET = frozenset(t.lower() for t in TECH_TERMS)

# Hunspell is used as a "is this a real word?" oracle: a term is only ever
# rewritten when NEITHER the Portuguese nor the English dictionary knows it, so
# real words ("permite", "pasta", "teste", "quebrou") are never touched.
HUNSPELL_DICTS = "pt_BR,en_US"

# The decoder's priming text. Kept to a single short Portuguese sentence plus the
# vocabulary list: whisper.cpp truncates initial_prompt to 224 tokens, and a
# mixed-language *vocabulary* is what stops the code-switching from turning into
# a phonetic mess. Deliberately NOT a dialogue sentence — priming Whisper with
# prose makes it continue that prose.
PROMPT_BASE = (
    "Termos de programação em inglês ditos no meio do português: "
    + ", ".join(TECH_TERMS) + "."
)


def _lev_bounded(a: str, b: str, cap: int) -> int:
    """Levenshtein distance, giving up (returning cap + 1) past `cap`."""
    la, lb = len(a), len(b)
    if abs(la - lb) > cap:
        return cap + 1
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        row_min = cur[0]
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if cur[j] < row_min:
                row_min = cur[j]
        if row_min > cap:
            return cap + 1
        prev = cur
    return prev[lb]


# word (lowercased) -> is it a real word? Filled lazily; a dict lookup keeps the
# common all-Portuguese utterance from ever spawning a process. Persisted to disk
# so the cost is only paid the very first time a word shows up, ever.
_huns_cache: dict[str, bool] = {}
_huns_lock = threading.Lock()
_huns_dirty = False
_huns_saved = 0.0
HUNS_CACHE_PATH = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"),
    "opencode-voice-words.json",
)


def _huns_load() -> None:
    global _huns_saved
    try:
        with open(HUNS_CACHE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for k, v in data.items():
                if isinstance(k, str) and isinstance(v, bool):
                    _huns_cache[k] = v
        _huns_saved = time.monotonic()
    except Exception:
        pass


def _huns_save(force: bool = False) -> None:
    global _huns_dirty, _huns_saved
    if not _huns_dirty:
        return
    if not force and time.monotonic() - _huns_saved < 20:
        return
    _huns_dirty = False
    _huns_saved = time.monotonic()
    try:
        os.makedirs(os.path.dirname(HUNS_CACHE_PATH), exist_ok=True)
        tmp = HUNS_CACHE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_huns_cache, f)
        os.replace(tmp, HUNS_CACHE_PATH)
    except Exception:
        pass


def _hunspell_known(words: list[str]) -> set[str]:
    """Subset of `words` hunspell accepts (pt_BR or en_US). Cached forever."""
    global _huns_dirty
    if not words:
        return set()
    with _huns_lock:
        todo = [w for w in words if w.lower() not in _huns_cache]
        if todo and shutil.which("hunspell"):
            try:
                res = subprocess.run(
                    ["hunspell", "-l", "-d", HUNSPELL_DICTS],
                    input="\n".join(todo),
                    capture_output=True,
                    text=True,
                    timeout=4,
                )
                bad = {w.strip().lower() for w in res.stdout.splitlines() if w.strip()}
                for w in todo:
                    _huns_cache[w.lower()] = w.lower() not in bad
                _huns_dirty = True
                _huns_save()
            except Exception:
                # no oracle → assume every token is a real word (never rewrite)
                return set(words)
        return {w for w in words if _huns_cache.get(w.lower(), True)}


WORD_RE = re.compile(r"[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ']*")

# High-confidence mishearings of technical terms. Applied ONLY to tokens
# hunspell rejects (so a real Portuguese/English word can never be rewritten),
# and before the fuzzy pass, because these are further away than the edit
# distance limit would allow.
EXACT_MISHEAR = {
    "tmute": "timeout", "timute": "timeout", "timeute": "timeout",
    "timout": "timeout", "taimaut": "timeout", "time out": "timeout",
    "teature": "feature", "teaturi": "feature", "teatura": "feature",
    "teatures": "features", "ticher": "feature", "ficher": "feature",
    "deploi": "deploy", "etoy": "deploy", "deploye": "deploy", "deplo": "deploy",
    "bild": "build", "bildi": "build", "biuld": "build", "plue": "build",
    "issu": "issue", "isue": "issue",
    "reques": "request", "requets": "request", "rike": "request",
    "rebais": "rebase", "rebrou": "rebase", "ribas": "rebase",
    "kesh": "cache", "cax": "cache",
    "comit": "commit", "commite": "commit", "comite": "commit",
    "bugfix": "bug fix",
    "back end": "backend", "front end": "frontend",
    "end point": "endpoint", "data base": "database",
}


# Snap tokens Whisper mangled into the nearest technical term. Two guards keep
# it from destroying legitimate speech: a token is only considered when it is
# already within a small edit distance of a known term, and it is only rewritten
# when hunspell confirms it is not a real Portuguese *or* English word.
def fix_tech_terms(text: str) -> str:
    if not text:
        return text

    # space-separated forms Whisper likes to split ("time out", "back end")
    for joined in sorted((k for k in EXACT_MISHEAR if " " in k),
                         key=len, reverse=True):
        if joined in text.lower():
            text = re.sub(re.escape(joined), EXACT_MISHEAR[joined], text,
                          flags=re.IGNORECASE)

    cand: dict[str, str] = {}
    for w in WORD_RE.findall(text):
        lw = w.lower()
        if len(lw) < 4 or lw in TERM_SET:
            continue
        hit = EXACT_MISHEAR.get(lw, "")
        if hit == "" and lw not in EXACT_MISHEAR:
            limit = 2 if len(lw) <= 6 else 3
            best, bestd = "", limit + 1
            for t in TERM_SET:
                if abs(len(t) - len(lw)) > limit:
                    continue
                d = _lev_bounded(lw, t, limit)
                if d > limit:
                    continue
                # a 2+ edit "match" is only trusted when the onset consonant
                # survived (Whisper keeps it far more often than not) —
                # without this "daon" would happily become "main"
                if d > 1 and lw[0] != t[0]:
                    continue
                if d < bestd or (d == bestd and len(t) < len(best)):
                    bestd, best = d, t
            if best and bestd <= limit:
                hit = best
        if hit:
            cand[w] = hit

    if not cand:
        return text

    # Ask the dictionary oracle only about the handful of near-miss tokens.
    known = _hunspell_known(sorted(set(cand)))
    repl = {w: c for w, c in cand.items() if w not in known}
    if not repl:
        return text
    return WORD_RE.sub(lambda m: repl.get(m.group(0), m.group(0)), text)


def scale_pcm(pcm_bytes: bytes, vol: float) -> bytes:
    n = len(pcm_bytes) & ~1
    if n < 2 or abs(vol - 1.0) < 0.01:
        return pcm_bytes[:n]
    if vol <= 0.001:
        return b"\x00" * n
    if np is not None:
        arr = np.frombuffer(pcm_bytes[:n], dtype=np.int16).astype(np.float32)
        np.multiply(arr, vol, out=arr)
        np.clip(arr, -32768.0, 32767.0, out=arr)
        return arr.astype(np.int16).tobytes()
    samples = array.array("h")
    samples.frombytes(pcm_bytes[:n])
    for i in range(len(samples)):
        v = int(samples[i] * vol)
        if v > 32767:
            v = 32767
        elif v < -32768:
            v = -32768
        samples[i] = v
    return samples.tobytes()


def shape_utterance_pcm(pcm_bytes: bytes, sr: int) -> bytes:
    """Apply a gentle 8ms fade-in/out and 45ms trailing breath pause so sentence
    boundaries never click or run words together."""
    n = len(pcm_bytes) & ~1
    if n < 4:
        return pcm_bytes[:n]
    pause_samples = int(sr * 0.045)
    pause_bytes = b"\x00" * (pause_samples * 2)
    fade_n = min(int(sr * 0.008), n // 4)
    if fade_n > 1 and np is not None:
        arr = np.frombuffer(pcm_bytes[:n], dtype=np.int16).astype(np.float32).copy()
        ramp = np.linspace(0.0, 1.0, fade_n, dtype=np.float32)
        arr[:fade_n] *= ramp
        arr[-fade_n:] *= ramp[::-1]
        return arr.astype(np.int16).tobytes() + pause_bytes
    return pcm_bytes[:n] + pause_bytes


def calc_rms(pcm_bytes: bytes) -> float:
    n = len(pcm_bytes) & ~1
    if n < 2:
        return 0.0
    if np is not None:
        arr = np.frombuffer(pcm_bytes[:n], dtype=np.int16).astype(np.float32)
        raw = float(np.sqrt(np.mean(arr * arr))) / 32768.0
    else:
        samples = array.array("h")
        samples.frombytes(pcm_bytes[:n])
        acc = 0.0
        for s in samples:
            acc += s * s
        raw = math.sqrt(acc / len(samples)) / 32768.0
    # perceptual curve so normal speech sits around 0.25..0.85
    return min(1.0, math.pow(raw * 6.5, 0.72))


def raw_rms(pcm_bytes: bytes) -> float:
    n = len(pcm_bytes) & ~1
    if n < 2:
        return 0.0
    if np is not None:
        arr = np.frombuffer(pcm_bytes[:n], dtype=np.int16).astype(np.float32)
        return float(np.sqrt(np.mean(arr * arr))) / 32768.0
    samples = array.array("h")
    samples.frombytes(pcm_bytes[:n])
    acc = 0.0
    for s in samples:
        acc += s * s
    return math.sqrt(acc / len(samples)) / 32768.0


def is_hallucination(text: str) -> bool:
    t = text.strip()
    if not t or len(t) < 2:
        return True
    if HALLUCINATION_RE.match(t):
        return True
    # strip bracketed tags like [Música]
    cleaned = re.sub(r"\[[^\]]*\]|\([^\)]*\)", "", t).strip()
    if not cleaned:
        return True
    low = cleaned.lower().strip(" .,!?;:-…\"'")
    if low in HALLUCINATIONS:
        return True
    if "legendas pela comunidade" in low or "amara.org" in low:
        return True
    return False


def guess_lang(text: str, preferred: str, last_detected: str) -> str:
    if preferred in ("pt", "en"):
        return preferred
    # Heuristic for sentence language so auto mode picks the right neural voice
    low = " " + text.lower() + " "
    if re.search(r"[ãõçáéíóúâêôà]", low):
        return "pt"
    pt_words = (" que ", " não ", " para ", " com ", " uma ", " está ", " você ", " isso ", " mais ", " como ", " pelo ", " são ")
    en_words = (" the ", " and ", " with ", " that ", " this ", " have ", " from ", " your ", " would ", " there ", " what ", " about ")
    pt_score = sum(1 for w in pt_words if w in low)
    en_score = sum(1 for w in en_words if w in low)
    if pt_score > en_score:
        return "pt"
    if en_score > pt_score:
        return "en"
    return last_detected if last_detected in ("pt", "en") else "pt"


# ---- Piper Neural TTS wrapper -----------------------------------------------
class VoiceConfig(NamedTuple):
    espeak_voice_name: str
    sample_rate: int
    phoneme_id_map: dict
    length_scale: float
    noise_scale: float
    noise_w: float
    num_speakers: int
    sentence_delay: float = 0.06
    normalize_volume: bool = False


class NeuralTTS:
    def __init__(self) -> None:
        self.piper = None
        self.configs: dict[str, tuple[VoiceConfig, str]] = {}
        self.active_lang = ""
        self.lock = threading.Lock()
        self._init_piper()

    def _init_piper(self) -> None:
        try:
            sys.path.insert(0, "/usr/lib/calibre/calibre/plugins")
            import piper  # type: ignore

            piper.initialize("")
            for lang, model_path in VOICES.items():
                cfg_path = model_path + ".json"
                if os.path.exists(model_path) and os.path.exists(cfg_path):
                    with open(cfg_path, "rb") as f:
                        x = json.load(f)
                    raw_id_map = x.get("phoneme_id_map", {})
                    phoneme_map = x.get("phoneme_map", {})
                    pmap: dict[int, list[int]] = {}
                    for s, pids in raw_id_map.items():
                        if not s:
                            continue
                        # Respect phoneme_map (e.g. pt_BR maps IPA 'c' -> ['k'])
                        # so espeak-ng palatal stops don't hit untrained IDs.
                        mapped = phoneme_map.get(s)
                        if mapped:
                            resolved: list[int] = []
                            for target in mapped:
                                resolved.extend(map(int, raw_id_map.get(target, pids)))
                            pmap[ord(s[0])] = resolved
                        else:
                            pmap.setdefault(ord(s[0]), []).extend(map(int, pids))
                    inf = x.get("inference", {})
                    cfg = VoiceConfig(
                        espeak_voice_name=x.get("espeak", {}).get("voice")
                        or ("pt-br" if lang == "pt" else "en-us"),
                        sample_rate=int(x.get("audio", {}).get("sample_rate", TTS_RATE)),
                        phoneme_id_map=pmap,
                        length_scale=float(inf.get("length_scale", 1.0)),
                        noise_scale=float(inf.get("noise_scale", 0.667)),
                        noise_w=float(inf.get("noise_w", 0.8)),
                        num_speakers=int(x.get("num_speakers", 1)),
                    )
                    self.configs[lang] = (cfg, model_path)
            if self.configs:
                self.piper = piper
                # Pre-warm default voice (pt if available, else en)
                first = "pt" if "pt" in self.configs else next(iter(self.configs))
                self._ensure_voice(first)
        except Exception:
            self.piper = None

    def _ensure_voice(self, lang: str) -> None:
        if not self.piper:
            return
        if lang not in self.configs:
            lang = next(iter(self.configs))
        if self.active_lang != lang:
            cfg, model_path = self.configs[lang]
            self.piper.set_voice(cfg, model_path)
            self.active_lang = lang

    def synthesize(self, text: str, lang: str) -> tuple[bytes, int]:
        if self.piper and self.configs:
            with self.lock:
                self._ensure_voice(lang)
                self.piper.start(text)
                chunks = []
                sr = TTS_RATE
                while True:
                    audio_data, _n, sample_rate, is_last = self.piper.next(True)
                    sr = sample_rate
                    if audio_data:
                        chunks.append(audio_data)
                    if is_last:
                        break
                raw_pcm = b"".join(chunks)
                return shape_utterance_pcm(raw_pcm, sr), sr
        # Fallback to espeak-ng stdout wav if piper is unavailable
        voice = "pt-br" if lang == "pt" else "en-us"
        try:
            proc = subprocess.run(
                ["espeak-ng", "-v", voice, "-s", "185", "--stdout", text],
                capture_output=True,
                timeout=8,
            )
            if proc.returncode == 0 and len(proc.stdout) > 44:
                return shape_utterance_pcm(proc.stdout[44:], 22050), 22050
        except Exception:
            pass
        return b"", TTS_RATE


# ---- Whisper STT Manager ----------------------------------------------------
class WhisperSTT:
    def __init__(self) -> None:
        self.port = self._pick_port()
        self.proc: subprocess.Popen | None = None
        self.ready = False
        # language used when auto-detection cannot be trusted (see transcribe)
        self.sticky_lang = "pt"
        self.quality = "accurate" if os.path.exists(WHISPER_MODELS["accurate"]) else "fast"
        self._start_server()

    def model_path(self) -> str:
        return WHISPER_MODELS.get(self.quality) or WHISPER_MODELS["fast"]

    # Swap between fast/accurate without blocking the mic loop: the server is
    # torn down and rebuilt on a worker thread, and `ready` flips back when the
    # new one answers.
    def set_quality(self, quality: str) -> None:
        if quality not in WHISPER_MODELS or quality == self.quality:
            return
        self.quality = quality

        def swap() -> None:
            self.stop()
            self._start_server()

        threading.Thread(target=swap, daemon=True).start()

    def _pick_port(self) -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _start_server(self) -> None:
        path = self.model_path()
        if not os.path.exists(path):
            return
        try:
            self.proc = subprocess.Popen(
                [
                    "whisper-server",
                    "-m", path,
                    "-t", "8",
                    "-bo", "1",
                    # beam search is nearly free here (the encoder dominates a
                    # short clip) and measurably better than greedy: 20.2% vs
                    # 24.2% WER for small, 11.3% vs 15.2% for medium-q5.
                    "-bs", "5",
                    "-nt",
                    "-sns",
                    "-l", "auto",
                    # the vocabulary primer; whisper-server has no per-request
                    # prompt field, so it must be set here (see PROMPT_BASE)
                    "--prompt", PROMPT_BASE,
                    "--host", "127.0.0.1",
                    "--port", str(self.port),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=_child_preexec,
            )
            threading.Thread(target=self._wait_ready, daemon=True).start()
        except Exception:
            self.proc = None

    def _wait_ready(self) -> None:
        for _ in range(120):
            if self.proc is None or self.proc.poll() is not None:
                return
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.15):
                    self.ready = True
                    emit({"type": "stt_ready", "quality": self.quality})
                    return
            except OSError:
                time.sleep(0.1)

    def stop(self) -> None:
        p = self.proc
        self.proc = None
        self.ready = False
        if p and p.poll() is None:
            try:
                p.terminate()
                p.wait(timeout=1.0)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass

    def _infer(self, wav_path: str, audio_ctx: int, w_lang: str) -> dict | None:
        """One /inference call. Returns the parsed verbose_json, or None."""
        if not (self.ready and self.proc and self.proc.poll() is None):
            return None
        try:
            res = subprocess.run(
                [
                    "curl", "-s", "-m", "10",
                    f"http://127.0.0.1:{self.port}/inference",
                    "-F", f"file=@{wav_path}",
                    "-F", "response_format=verbose_json",
                    "-F", "temperature=0.0",
                    "-F", f"audio_ctx={audio_ctx}",
                    "-F", f"language={w_lang}",
                    # The vocabulary primer is a *startup* option (--prompt):
                    # 'prompt' is NOT in the server's form-field table and was
                    # silently ignored when it was sent here. These two ARE
                    # per request:
                    #   no_speech_thold — keep quiet-but-real speech (the default
                    #     0.6 drops segments on a soft mic)
                    #   temperature_inc — re-enable the fallback, so a
                    #     degenerate decode is retried instead of accepted
                    "-F", "no_speech_thold=0.9",
                    "-F", "temperature_inc=0.2",
                ],
                capture_output=True,
                text=True,
                timeout=11,
            )
            if res.returncode == 0 and res.stdout.strip():
                return json.loads(res.stdout)
        except Exception:
            pass
        return None

    def transcribe(self, wav_path: str, duration_s: float, lang: str) -> tuple[str, str]:
        # Scale Whisper's encoder audio_ctx to clip length (50 ctx frames = 1s)
        # with comfortable headroom so short utterances take ~250ms instead of
        # ~1.8s. The floor is well above the bare minimum: over-compressing the
        # encoder is what makes accented/mixed-language words come out wrong.
        # (Measured: clamping to the full 1500 instead costs 2.3x the time and
        # scores *worse*, so the adaptive window stays.)
        audio_ctx = max(512, min(1500, ((int(duration_s * 50) + 128 + 63) // 64) * 64))
        wanted_auto = lang not in ("pt", "en")
        w_lang = "auto" if wanted_auto else lang

        data = self._infer(wav_path, audio_ctx, w_lang)

        # `auto` on a short, accented clip is a coin flip: the detector happily
        # reports welsh/nynorsk with a ~0.15 probability and the whole utterance
        # is then decoded in that language — pure garbage. Whenever it does not
        # land on a language we actually speak, redo the call pinned to the
        # language the user has been speaking all along.
        if data is not None and wanted_auto:
            probs = data.get("language_probabilities") or {}
            det_lang = str(data.get("detected_language") or data.get("language") or "").lower()
            pt_p = float(probs.get("pt", 0.0))
            en_p = float(probs.get("en", 0.0))
            known = ("portuguese" in det_lang or det_lang == "pt"
                     or "english" in det_lang or det_lang == "en")
            if not known and pt_p <= 0.0 and en_p <= 0.0:
                pinned = self.sticky_lang if self.sticky_lang in ("pt", "en") else "pt"
                retry = self._infer(wav_path, audio_ctx, pinned)
                if retry is not None:
                    data, w_lang = retry, pinned

        if data is not None:
            text = (data.get("text") or "").strip()
            det = str(data.get("detected_language") or data.get("language") or "").lower()
            probs = data.get("language_probabilities") or {}
            if w_lang == "auto" and probs:
                pt_p = float(probs.get("pt", 0.0))
                en_p = float(probs.get("en", 0.0))
                det_code = "pt" if pt_p >= en_p * 0.55 else "en"
            elif "portuguese" in det or det == "pt":
                det_code = "pt"
            elif "english" in det or det == "en":
                det_code = "en"
            else:
                det_code = w_lang if w_lang in ("pt", "en") else self.sticky_lang
            self.sticky_lang = det_code
            return text, det_code

        # Fallback: direct whisper-cli (used when the server is not up)
        try:
            res = subprocess.run(
                [
                    "whisper-cli",
                    "-t", "8",
                    "-bo", "1",
                    "-bs", "1",
                    "-sns",
                    "-np",
                    "-nt",
                    "-ac", str(audio_ctx),
                    "-m", self.model_path(),
                    "-l", w_lang,
                    "--prompt", PROMPT_BASE,
                    "-f", wav_path,                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            text = (res.stdout or "").strip()
            return text, (lang if lang in ("pt", "en") else "pt")
        except Exception:
            return "", "pt"


# ---- Full-Duplex Coordinator ------------------------------------------------
class VoiceDaemon:
    def __init__(self) -> None:
        self.stt = WhisperSTT()
        self.tts = NeuralTTS()
        self.lang = "pt"                 # "pt" | "en" | "auto"
        self.last_detected_lang = "pt"
        # voice used for the assistant's CURRENT reply. In auto mode the choice
        # is made once per reply from its first sentence and then held, instead
        # of re-deciding every sentence (which made one answer switch voices
        # mid-sentence, i.e. "mixing the languages").
        self.reply_lang = ""
        self.muted = False
        self.assistant_busy = False
        self.running = True

        # TTS state
        self.volume = 0.85
        self.tts_gen = 0
        self.tts_lock = threading.Lock()
        self.synth_queue: queue.Queue[tuple[int, str] | None] = queue.Queue()
        self.play_queue: queue.Queue[tuple[int, str, bytes, int] | None] = queue.Queue()
        self.play_proc: subprocess.Popen | None = None
        self.tts_playing = False
        self.tts_current_rms = 0.0
        self.tts_ended_at = 0.0
        self.pending_synth = 0

        # Mic / VAD state
        self.rec_procs: list[subprocess.Popen] = []
        self.in_speech_active = False
        self.force_commit = False
        self.transcribing = False
        self.wav_path = os.path.join(
            tempfile.gettempdir(), f"opencode-voice-{os.getpid()}.wav"
        )

    def start(self) -> None:
        threading.Thread(target=self._synth_loop, daemon=True).start()
        threading.Thread(target=self._play_loop, daemon=True).start()
        threading.Thread(target=self._mic_loop, daemon=True).start()
        emit({
            "type": "ready",
            "stt": "server",
            "tts": "piper" if self.tts.piper else "espeak",
            "quality": self.stt.quality,
        })
        self._stdin_loop()

    def _stop_rec_procs(self) -> None:
        procs = self.rec_procs[:]
        self.rec_procs.clear()
        for p in procs:
            if p and p.poll() is None:
                try:
                    p.terminate()
                except Exception:
                    pass

    def shutdown(self) -> None:
        self.running = False
        self.stop_tts()
        self._stop_rec_procs()
        self.stt.stop()
        try:
            if os.path.exists(self.wav_path):
                os.remove(self.wav_path)
        except Exception:
            pass

    # ---- TTS pipeline -------------------------------------------------------
    def enqueue_speak(self, text: str) -> None:
        clean = text.strip()
        if not clean or self.in_speech_active or self.transcribing:
            return
        with self.tts_lock:
            gen = self.tts_gen
            self.pending_synth += 1
        self.synth_queue.put((gen, clean))

    def stop_tts(self) -> None:
        with self.tts_lock:
            self.tts_gen += 1
            self.pending_synth = 0
            was_playing = self.tts_playing
            self.tts_playing = False
            self.tts_current_rms = 0.0
            p = self.play_proc
            self.play_proc = None
        # Drain queues
        while not self.synth_queue.empty():
            try:
                self.synth_queue.get_nowait()
            except queue.Empty:
                break
        while not self.play_queue.empty():
            try:
                self.play_queue.get_nowait()
            except queue.Empty:
                break
        if p and p.poll() is None:
            try:
                p.kill()
            except Exception:
                pass
        if was_playing:
            self.tts_ended_at = time.monotonic()
            emit({"type": "tts_done"})

    def _synth_loop(self) -> None:
        while self.running:
            item = self.synth_queue.get()
            if item is None:
                break
            gen, text = item
            if gen != self.tts_gen:
                continue
            if self.lang in ("pt", "en"):
                lang = self.lang
            elif self.reply_lang:
                lang = self.reply_lang
            else:
                lang = guess_lang(text, self.lang, self.last_detected_lang)
                self.reply_lang = lang
            pcm, sr = self.tts.synthesize(text, lang)
            with self.tts_lock:
                if gen != self.tts_gen:
                    continue
                self.pending_synth = max(0, self.pending_synth - 1)
                if pcm:
                    self.play_queue.put((gen, text, pcm, sr))
                elif self.pending_synth == 0 and self.play_queue.empty() and not self.tts_playing:
                    emit({"type": "tts_done"})

    def _ensure_play_proc(self, sr: int) -> subprocess.Popen | None:
        with self.tts_lock:
            if self.play_proc and self.play_proc.poll() is None:
                return self.play_proc
            try:
                self.play_proc = subprocess.Popen(
                    [
                        "pw-cat", "-p",
                        "--raw",
                        "--rate", str(sr),
                        "--channels", "1",
                        "--format", "s16",
                        "-",
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    preexec_fn=_child_preexec,
                )
                return self.play_proc
            except Exception:
                self.play_proc = None
                return None

    def _close_play_proc(self) -> None:
        with self.tts_lock:
            p = self.play_proc
            self.play_proc = None
        if p:
            try:
                if p.stdin:
                    p.stdin.close()
                p.wait(timeout=0.6)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass

    def _play_loop(self) -> None:
        while self.running:
            try:
                first_item = self.play_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if first_item is None:
                break
            gen, first_text, first_pcm, sr = first_item
            if gen != self.tts_gen:
                continue

            proc = self._ensure_play_proc(sr)
            if not proc or not proc.stdin:
                continue

            with self.tts_lock:
                if gen != self.tts_gen:
                    continue
                self.tts_playing = True

            # Continuous stream state across all sentences of a reply:
            # - `audio_buf` holds raw s16le PCM bytes queued for playback
            # - `write_ofs` is how many bytes have been written into pw-cat's pipe
            # - `play_ofs` is how many bytes have actually played out of the speakers
            # Keeping `write_ofs` ~320ms (PIPE_PREBUFFER_S) ahead of `play_ofs` in
            # 4096-byte aligned writes guarantees pw-cat's fread(stdin) inside
            # PipeWire's real-time callback never blocks or underruns.
            audio_buf = bytearray(first_pcm)
            captions: collections.deque[tuple[int, str]] = collections.deque()
            emit({"type": "tts_start", "text": first_text})

            write_ofs = 0
            play_ofs = 0
            bytes_per_sec = sr * 2
            prebuf_bytes = ((int(bytes_per_sec * PIPE_PREBUFFER_S) + PIPE_BLOCK_BYTES - 1)
                            // PIPE_BLOCK_BYTES) * PIPE_BLOCK_BYTES
            slice_dur = TTS_CHUNK_SAMPLES / float(sr)
            t_next = time.monotonic()
            idle_wait_s = 0.0
            stream_aborted = False

            while self.running:
                if gen != self.tts_gen or self.in_speech_active:
                    stream_aborted = True
                    break

                # Pull any newly synthesized sentences onto the same contiguous buffer
                while True:
                    try:
                        nxt = self.play_queue.get_nowait()
                    except queue.Empty:
                        break
                    if nxt is None:
                        self.running = False
                        stream_aborted = True
                        break
                    ngen, ntext, npcm, _nsr = nxt
                    if ngen != gen:
                        continue
                    captions.append((len(audio_buf), ntext))
                    audio_buf.extend(npcm)
                    idle_wait_s = 0.0

                if stream_aborted:
                    break

                # If we are running low on buffered bytes to feed pw-cat, check
                # whether more sentences are still being synthesized or streamed
                target_write = play_ofs + prebuf_bytes
                if len(audio_buf) < target_write:
                    with self.tts_lock:
                        waiting_more = (self.pending_synth > 0 or self.assistant_busy)
                    if waiting_more and idle_wait_s < 0.72:
                        # Pad with a 4096-byte silent block so PipeWire's callback
                        # never blocks while waiting for the next sentence
                        audio_buf.extend(b"\x00" * PIPE_BLOCK_BYTES)
                        idle_wait_s += PIPE_BLOCK_BYTES / float(bytes_per_sec)
                    elif len(audio_buf) % PIPE_BLOCK_BYTES != 0:
                        pad = PIPE_BLOCK_BYTES - (len(audio_buf) % PIPE_BLOCK_BYTES)
                        audio_buf.extend(b"\x00" * pad)

                # Top up pw-cat's stdin pipe up to target_write in 4096-byte blocks
                while write_ofs < min(len(audio_buf), target_write):
                    step = min(PIPE_BLOCK_BYTES, len(audio_buf) - write_ofs)
                    raw_block = bytes(audio_buf[write_ofs : write_ofs + step])
                    write_ofs += step
                    scaled_block = scale_pcm(raw_block, self.volume)
                    try:
                        proc.stdin.write(scaled_block)
                        proc.stdin.flush()
                    except Exception:
                        stream_aborted = True
                        break

                if stream_aborted:
                    break

                # If all synthesized audio has been written and nothing else is
                # pending, close stdin so pw-cat sees EOF cleanly without blocking
                with self.tts_lock:
                    more_coming = not self.play_queue.empty() or self.pending_synth > 0
                if write_ofs >= len(audio_buf) and not more_coming and proc.stdin and not proc.stdin.closed:
                    try:
                        proc.stdin.close()
                    except Exception:
                        pass

                # Advance the real-time playhead by one 40ms UI slice
                if play_ofs >= len(audio_buf):
                    if not more_coming:
                        break
                else:
                    while captions and play_ofs >= captions[0][0]:
                        _, cap_text = captions.popleft()
                        emit({"type": "tts_start", "text": cap_text})

                    raw_slice = bytes(audio_buf[play_ofs : play_ofs + TTS_CHUNK_BYTES])
                    play_ofs += TTS_CHUNK_BYTES
                    scaled_slice = scale_pcm(raw_slice, self.volume)
                    rms = calc_rms(scaled_slice)
                    self.tts_current_rms = rms
                    emit({"type": "tts_level", "rms": round(rms, 3)})

                    # Free already-played prefix periodically so long replies stay tiny
                    if play_ofs >= 65536 and write_ofs >= play_ofs:
                        drop = play_ofs & ~(PIPE_BLOCK_BYTES - 1)
                        if drop > 0:
                            del audio_buf[:drop]
                            write_ofs -= drop
                            play_ofs -= drop
                            captions = collections.deque(
                                ( max(0, pos - drop), txt ) for pos, txt in captions
                            )

                t_next += slice_dur
                sleep_s = t_next - time.monotonic()
                if sleep_s > 0:
                    time.sleep(sleep_s)
                elif sleep_s < -0.15:
                    t_next = time.monotonic()

            self.tts_current_rms = 0.0
            self._close_play_proc()

            with self.tts_lock:
                still_more = not self.play_queue.empty() or self.pending_synth > 0
                if gen == self.tts_gen and not still_more:
                    self.tts_playing = False
                    self.tts_ended_at = time.monotonic()
                    emit({"type": "tts_done"})

    # ---- Microphone + Adaptive VAD + Barge-in -------------------------------
    def _discover_sources(self) -> list[str | None]:
        try:
            out = subprocess.check_output(
                ["pactl", "list", "sources", "short"],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=2,
            )
            srcs: list[str | None] = []
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 2 and not parts[1].endswith(".monitor"):
                    srcs.append(parts[1])
            if srcs:
                return srcs
        except Exception:
            pass
        return [None]

    def _mic_reader(
        self,
        idx: int,
        proc: subprocess.Popen,
        fq: "queue.Queue[tuple[int, bytes] | None]",
    ) -> None:
        stdout = proc.stdout
        while self.running and stdout:
            try:
                buf = stdout.read(FRAME_BYTES)
            except Exception:
                break
            if not buf or len(buf) < FRAME_BYTES:
                break
            try:
                fq.put_nowait((idx, buf))
            except queue.Full:
                pass
        try:
            fq.put_nowait(None)
        except queue.Full:
            pass

    def _mic_loop(self) -> None:
        while self.running:
            sources = self._discover_sources()
            fq: queue.Queue[tuple[int, bytes] | None] = queue.Queue(maxsize=256)
            self._stop_rec_procs()

            for idx, src in enumerate(sources):
                cmd = [
                    "pw-record",
                    "--raw",
                    "--rate", str(MIC_RATE),
                    "--channels", "1",
                    "--format", "s16",
                ]
                if src:
                    cmd.extend(["--target", src])
                cmd.append("-")
                try:
                    p = subprocess.Popen(
                        cmd,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        preexec_fn=_child_preexec,
                    )
                    self.rec_procs.append(p)
                    threading.Thread(
                        target=self._mic_reader,
                        args=(idx, p, fq),
                        daemon=True,
                    ).start()
                except Exception as e:
                    emit({"type": "error", "message": f"mic failed: {e}"})

            if not self.rec_procs:
                time.sleep(1.5)
                continue

            n_src = len(self.rec_procs)
            prerolls = [
                collections.deque(maxlen=PREROLL_FRAMES) for _ in range(n_src)
            ]
            noise_floors = [0.004 for _ in range(n_src)]
            above_counts = [0 for _ in range(n_src)]
            latest_vis = [0.0 for _ in range(n_src)]

            speech_frames: list[bytes] = []
            in_speech = False
            active_mic = 0
            locked_mic: int | None = None
            silence_count = 0
            peak_raw = 0.0
            last_vis_emit = 0.0

            while self.running:
                try:
                    item = fq.get(timeout=0.5)
                except queue.Empty:
                    if all(p.poll() is not None for p in self.rec_procs):
                        break
                    continue
                if item is None:
                    if all(p.poll() is not None for p in self.rec_procs):
                        break
                    continue

                idx, buf = item
                now = time.monotonic()

                if self.muted or self.transcribing:
                    for d in prerolls:
                        d.clear()
                    speech_frames.clear()
                    in_speech = False
                    self.in_speech_active = False
                    above_counts = [0 for _ in range(n_src)]
                    silence_count = 0
                    if now - last_vis_emit >= 0.06:
                        last_vis_emit = now
                        emit({"type": "mic_level", "rms": 0.0, "speaking": False})
                    continue

                r_raw = raw_rms(buf)
                r_vis = calc_rms(buf)
                latest_vis[idx] = r_vis

                # Post-TTS cooldown (220ms) avoids room reverb triggering false VAD
                since_tts = now - self.tts_ended_at
                if not self.tts_playing and since_tts < 0.22:
                    prerolls[idx].append(buf)
                    above_counts[idx] = 0
                    continue

                nf = noise_floors[idx]
                if not in_speech and not self.tts_playing:
                    if r_raw < nf * 2.2:
                        nf = nf * 0.96 + r_raw * 0.04
                        nf = max(0.002, min(0.022, nf))
                        noise_floors[idx] = nf

                if self.tts_playing:
                    # While the assistant is speaking, ignore secondary/ambient mics
                    # once the user's primary mic is known, and require a firmer
                    # sustained voice signal (~224ms) above speaker bleed so TTS
                    # never cuts itself off on echo or brief clicks.
                    if locked_mic is not None and idx != locked_mic:
                        prerolls[idx].append(buf)
                        continue
                    bleed = self.tts_current_rms * (0.042 * max(0.35, self.volume))
                    thresh = max(0.020, min(0.065, nf * 3.4 + bleed))
                    req_frames = BARGE_FRAMES
                else:
                    thresh = max(0.0085, min(0.032, nf * 2.5))
                    req_frames = START_FRAMES

                if not in_speech:
                    if self.force_commit:
                        self.force_commit = False
                    prerolls[idx].append(buf)
                    if r_raw >= thresh:
                        above_counts[idx] += 1
                        if above_counts[idx] >= req_frames:
                            in_speech = True
                            self.in_speech_active = True
                            active_mic = idx
                            locked_mic = idx
                            silence_count = 0
                            peak_raw = r_raw
                            speech_frames = list(prerolls[idx])
                            above_counts = [0 for _ in range(n_src)]
                            if self.tts_playing or self.assistant_busy:
                                self.stop_tts()
                                emit({"type": "barge_in"})
                            else:
                                emit({"type": "vad_start"})
                    else:
                        above_counts[idx] = max(0, above_counts[idx] - 1)

                    if not self.tts_playing and now - last_vis_emit >= 0.055:
                        last_vis_emit = now
                        emit({
                            "type": "mic_level",
                            "rms": round(max(latest_vis), 3),
                            "speaking": False,
                        })
                else:
                    # Stay locked on the microphone that triggered speech
                    if idx != active_mic:
                        continue
                    speech_frames.append(buf)
                    if r_raw > peak_raw:
                        peak_raw = r_raw

                    # Gentle hysteresis once speaking so soft syllables/consonants
                    # and brief breaths mid-sentence never cut off speech early
                    cont_thresh = max(0.0045, min(0.014, max(nf * 1.5, thresh * 0.42)))
                    if r_raw < cont_thresh:
                        silence_count += 1
                    else:
                        silence_count = 0

                    if now - last_vis_emit >= 0.055:
                        last_vis_emit = now
                        emit({
                            "type": "mic_level",
                            "rms": round(r_vis, 3),
                            "speaking": True,
                        })

                    should_end = (
                        silence_count >= SILENCE_FRAMES
                        or len(speech_frames) >= MAX_SPEECH_FRAMES
                        or self.force_commit
                    )
                    if should_end:
                        forced = self.force_commit
                        self.force_commit = False
                        # Trim the trailing silence tail (keep ~320ms of trailing silence
                        # so Whisper hears clean word endings without a 1.4s dead tail)
                        if not forced and silence_count > 10 and len(speech_frames) > silence_count:
                            trim = silence_count - 10
                            frames_copy = speech_frames[:-trim]
                        else:
                            frames_copy = speech_frames[:]
                        speech_frames.clear()
                        for d in prerolls:
                            d.clear()
                        in_speech = False
                        self.in_speech_active = False
                        above_counts = [0 for _ in range(n_src)]
                        silence_count = 0

                        voiced_frames = len(frames_copy) - PREROLL_FRAMES
                        if not forced and (voiced_frames < MIN_SPEECH_FRAMES or peak_raw < 0.010):
                            emit({"type": "stt_empty"})
                            continue

                        threading.Thread(
                            target=self._run_stt,
                            args=(frames_copy,),
                            daemon=True,
                        ).start()

            self._stop_rec_procs()
            if self.running:
                time.sleep(0.3)

    def _run_stt(self, frames: list[bytes]) -> None:
        self.transcribing = True
        emit({"type": "stt_start"})
        t0 = time.monotonic()
        try:
            pcm = b"".join(frames)
            dur_s = len(pcm) / float(MIC_RATE * 2)
            with wave.open(self.wav_path, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(MIC_RATE)
                wf.writeframes(pcm)

            text, det_lang = self.stt.transcribe(self.wav_path, dur_s, self.lang)
            text = re.sub(r"\[[^\]]*\]", "", text)
            text = re.sub(r"\s+", " ", text).strip()
            # snap mangled technical terms ("teature" → "feature") before the
            # text leaves the daemon; hunspell guarantees real words survive
            text = fix_tech_terms(text)
            ms = int((time.monotonic() - t0) * 1000)

            if is_hallucination(text):
                emit({"type": "stt_empty"})
            else:
                self.last_detected_lang = det_lang
                self.reply_lang = ""      # a new reply picks its voice fresh
                emit({
                    "type": "transcript",
                    "text": text,
                    "lang": det_lang,
                    "ms": ms,
                })
        except Exception as e:
            emit({"type": "error", "message": f"stt error: {e}"})
            emit({"type": "stt_empty"})
        finally:
            self.transcribing = False

    # ---- Command loop (stdin) -----------------------------------------------
    def _stdin_loop(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            cmd = msg.get("cmd")
            if cmd == "speak":
                self.enqueue_speak(str(msg.get("text") or ""))
            elif cmd == "stop_tts":
                self.stop_tts()
            elif cmd == "mute":
                self.muted = bool(msg.get("muted"))
                if self.muted:
                    self.force_commit = False
            elif cmd == "lang":
                lang = str(msg.get("lang") or "pt")
                if lang in ("pt", "en", "auto"):
                    self.lang = lang
            elif cmd == "stt":
                q = str(msg.get("quality") or "")
                if q in WHISPER_MODELS:
                    self.stt.set_quality(q)
                    emit({"type": "stt_quality", "quality": q})
            elif cmd == "volume":
                try:
                    self.volume = max(0.0, min(1.5, float(msg.get("volume", 0.85))))
                except Exception:
                    pass
            elif cmd == "commit":
                self.force_commit = True
            elif cmd == "assistant_busy":
                self.assistant_busy = bool(msg.get("busy"))
            elif cmd == "quit":
                break


def main() -> None:
    _huns_load()
    daemon = VoiceDaemon()
    atexit.register(lambda: _huns_save(True))
    atexit.register(daemon.shutdown)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    daemon.start()


if __name__ == "__main__":
    main()
