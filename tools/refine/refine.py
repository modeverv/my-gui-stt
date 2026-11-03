"""Local refinement pipeline for LocalSpeechSTT transcripts (experimental).

Input : segments JSON written by `LocalSpeechSTT --cli <media> --speakers 0 --json-out raw.json`
        (Apple SpeechTranscriber result with character-level token timestamps) and the media file.
Stages (each cached in --work-dir, timings recorded in timings.json):
  1. whisper  : mlx-whisper (large-v3-turbo) second transcription with word timestamps
  2. speakers : neural speaker embeddings (sherpa-onnx ERes2Net / ResNet34) on 1.5 s windows of the
                speech regions, spectral clustering (eigengap -> speaker count), token-level Viterbi
                assignment on the Apple tokens; utterances are split at speaker changes
  3. correct  : Gemma (mlx-lm, ~4B, 4bit) under tight constraints: (a) a term table (misspelled
                technical terms -> canonical form) built once from the whole transcript, (b) for every
                place where Apple and Whisper heard *different* words, pick A or B. The Apple text stays
                the base, so fillers, timing and segment boundaries are preserved
  4. report   : one JSON with everything needed for side-by-side evaluation

Everything runs locally; no network access except the initial model download.
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import subprocess
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
MODELS = HERE / "models"
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
GEMMA_REPO = "mlx-community/gemma-4-e4b-it-4bit"
EMBEDDING_MODELS = {
    "eres2net": MODELS / "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
    "resnet34": MODELS / "wespeaker_en_voxceleb_resnet34_LM.onnx",
}

PUNCT = set("。、？！?!,.，")


# ----------------------------------------------------------------------------- utils

def load_json(p: Path):
    return json.loads(p.read_text())


def save_json(p: Path, obj) -> None:
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=1))


def normalize(text: str) -> str:
    """Comparison form: NFKC, no whitespace / punctuation, lower case."""
    t = unicodedata.normalize("NFKC", text).lower()
    return re.sub(r"[\s。、，,.？?！!「」『』()（）・…ー〜~-]", "", t)


def similarity(a: str, b: str) -> float:
    a, b = normalize(a), normalize(b)
    if not a and not b:
        return 1.0
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()


class Timer:
    def __init__(self, work: Path):
        self.path = work / "timings.json"
        self.data = load_json(self.path) if self.path.exists() else {}

    def record(self, stage: str, seconds: float) -> None:
        self.data[stage] = round(seconds, 2)
        save_json(self.path, self.data)


def decode_audio(media: Path, work: Path) -> Path:
    wav = work / "audio16k.wav"
    if not wav.exists():
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(media), "-ac", "1", "-ar", "16000", str(wav)],
            check=True,
        )
    return wav


# ----------------------------------------------------------------------------- 1. whisper

def stage_whisper(wav: Path, work: Path, timer: Timer) -> dict:
    out = work / "whisper.json"
    if out.exists():
        return load_json(out)
    import mlx_whisper

    t0 = time.time()
    result = mlx_whisper.transcribe(
        str(wav),
        path_or_hf_repo=WHISPER_REPO,
        language="ja",
        word_timestamps=True,
        condition_on_previous_text=False,  # avoids long hallucination loops on podcasts
        verbose=False,
    )
    timer.record("whisper", time.time() - t0)
    words = []
    for seg in result["segments"]:
        for w in seg.get("words", []):
            words.append({"text": w["word"], "start": float(w["start"]), "end": float(w["end"])})
    data = {"text": result["text"], "words": words,
            "segments": [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in result["segments"]]}
    save_json(out, data)
    return data


def whisper_text_between(words: list[dict], start: float, end: float) -> str:
    """Whisper words whose midpoint lies inside [start, end)."""
    picked = [w["text"] for w in words if start <= (w["start"] + w["end"]) / 2 < end]
    return "".join(picked).strip()


# ----------------------------------------------------------------------------- 2. speakers

WINDOW = 1.5      # seconds of audio per speaker embedding
HOP = 0.75
MAX_AUTO_SPEAKERS = 6


def speech_regions(raw_segments: list[dict], max_gap: float = 0.3) -> list[tuple[float, float]]:
    """Speech regions from the Apple token timestamps (shifted to audio time)."""
    spans = []
    for seg in raw_segments:
        for t in seg.get("tokens") or [{"startTime": seg["startTime"], "endTime": seg["endTime"]}]:
            spans.append((t["startTime"] + TOKEN_TIME_SHIFT, t["endTime"] + TOKEN_TIME_SHIFT))
    spans.sort()
    regions: list[list[float]] = []
    for a, b in spans:
        if regions and a - regions[-1][1] <= max_gap:
            regions[-1][1] = max(regions[-1][1], b)
        else:
            regions.append([a, b])
    return [(a, b) for a, b in regions if b - a >= 0.5]


def windows_for(regions: list[tuple[float, float]]) -> list[tuple[float, float]]:
    wins = []
    for a, b in regions:
        if b - a <= WINDOW:
            wins.append((a, b))
            continue
        t = a
        while t + WINDOW <= b + 1e-6:
            wins.append((t, t + WINDOW))
            t += HOP
        if wins[-1][1] < b - 0.3:
            wins.append((b - WINDOW, b))
    return wins


def spectral_cluster(emb: np.ndarray, fixed_k: int | None) -> np.ndarray:
    """Same recipe as the app's SpectralClusterer: pruned cosine graph, normalized Laplacian, eigengap."""
    n = len(emb)
    x = emb - emb.mean(axis=0)
    x /= np.linalg.norm(x, axis=1, keepdims=True) + 1e-9
    sim = x @ x.T
    p = max(4, min(n - 1, int(n * 0.12)))
    aff = np.zeros_like(sim)
    np.fill_diagonal(sim, -np.inf)
    idx = np.argpartition(-sim, p, axis=1)[:, :p]
    rows = np.repeat(np.arange(n), p)
    aff[rows, idx.ravel()] = 1.0
    aff = 0.5 * (aff + aff.T)
    d = 1 / np.sqrt(np.maximum(aff.sum(1), 1e-6))
    lap = np.eye(n) - aff * d[:, None] * d[None, :]
    vals, vecs = np.linalg.eigh(lap)
    if fixed_k:
        k = fixed_k
    else:
        gaps = np.diff(vals[: MAX_AUTO_SPEAKERS + 1])
        k = int(np.argmax(gaps)) + 1
    if k <= 1:
        return np.zeros(n, dtype=int)
    v = vecs[:, :k]
    v /= np.linalg.norm(v, axis=1, keepdims=True) + 1e-9
    best, best_inertia = None, np.inf
    rng = np.random.default_rng(0)
    for _ in range(10):
        centers = v[rng.choice(n, k, replace=False)]
        for _ in range(50):
            lab = np.argmin(((v[:, None, :] - centers[None]) ** 2).sum(-1), axis=1)
            new = np.array([v[lab == c].mean(0) if np.any(lab == c) else centers[c] for c in range(k)])
            if np.allclose(new, centers):
                break
            centers = new
        inertia = ((v - centers[lab]) ** 2).sum()
        if inertia < best_inertia:
            best, best_inertia = lab, inertia
    return best


def stage_neural_diarization(wav: Path, raw_segments: list[dict], work: Path, timer: Timer,
                             embedding: str, num_speakers: int) -> dict:
    out = work / f"neural_windows_{embedding}.npz"
    import sherpa_onnx
    import soundfile as sf

    regions = speech_regions(raw_segments)
    wins = windows_for(regions)
    if out.exists():
        emb = np.load(out)["emb"]
    else:
        extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMBEDDING_MODELS[embedding]), num_threads=6))
        audio, sr = sf.read(str(wav), dtype="float32")
        t0 = time.time()
        vecs = []
        for a, b in wins:
            stream = extractor.create_stream()
            stream.accept_waveform(sr, audio[int(a * sr): int(b * sr)])
            stream.input_finished()
            vecs.append(np.array(extractor.compute(stream), dtype=np.float32))
        emb = np.stack(vecs)
        timer.record(f"neural_embeddings_{embedding}", time.time() - t0)
        np.savez(out, emb=emb)

    t0 = time.time()
    labels = spectral_cluster(emb, num_speakers if num_speakers > 0 else None)
    k = int(labels.max()) + 1
    # cosine similarity of every window to every speaker centroid -> evidence for token decoding
    x = emb / (np.linalg.norm(emb, axis=1, keepdims=True) + 1e-9)
    cents = np.stack([x[labels == c].mean(0) for c in range(k)])
    cents /= np.linalg.norm(cents, axis=1, keepdims=True) + 1e-9
    sims = x @ cents.T
    timer.record("neural_clustering", time.time() - t0)
    return {"windows": wins, "sims": sims, "k": k}


@dataclass
class Unit:
    seg_index: int
    token_index: int
    start: float
    end: float
    text: str


TOKEN_TIME_SHIFT = 0.1          # Apple token timestamps run ~0.1 s ahead of the audio
EMISSION_SCALE = 25.0           # emission = overlap seconds * centred cosine similarity * scale
PENALTY_CONTINUOUS = 2.5
PENALTY_PUNCT = 0.6
PENALTY_PAUSE = 0.4


def assign_speakers_to_tokens(raw_segments: list[dict], neural: dict) -> list[dict]:
    """Token-level Viterbi over Apple tokens using window/centroid similarities as evidence."""
    k = neural["k"]
    wins = neural["windows"]
    sims = neural["sims"]
    centred = sims - sims.mean(axis=1, keepdims=True)
    win_starts = np.array([w[0] for w in wins])

    units: list[Unit] = []
    for si, seg in enumerate(raw_segments):
        toks = seg.get("tokens") or [{"text": seg["text"], "startTime": seg["startTime"], "endTime": seg["endTime"]}]
        for ti, t in enumerate(toks):
            units.append(Unit(si, ti, t["startTime"], t["endTime"], t["text"]))

    m = len(units)
    emission = np.zeros((m, max(k, 1)))
    for i, u in enumerate(units):
        a, b = u.start + TOKEN_TIME_SHIFT, u.end + TOKEN_TIME_SHIFT
        lo = np.searchsorted(win_starts, a - WINDOW)
        hi = np.searchsorted(win_starts, b)
        for w in range(lo, hi):
            ov = min(b, wins[w][1]) - max(a, wins[w][0])
            if ov > 0:
                # windows centred on the token are the most informative about it
                centre = (wins[w][0] + wins[w][1]) / 2
                half = (wins[w][1] - wins[w][0]) / 2 + 0.1
                weight = max(0.1, 1 - abs((a + b) / 2 - centre) / half)
                emission[i] += ov * weight * centred[w] * EMISSION_SCALE

    penalties = np.zeros(m)
    for i in range(1, m):
        prev, cur = units[i - 1], units[i]
        gap = cur.start - prev.end
        if cur.seg_index != prev.seg_index or gap >= 0.15:
            penalties[i] = PENALTY_PAUSE
        elif prev.text.strip() and prev.text.strip()[-1] in PUNCT:
            penalties[i] = PENALTY_PUNCT
        else:
            penalties[i] = PENALTY_CONTINUOUS

    # Viterbi
    delta = emission[0].copy()
    back = np.zeros((m, k), dtype=np.int32)
    for i in range(1, m):
        best_prev = int(np.argmax(delta))
        switch = delta[best_prev] - penalties[i]
        stay_better = delta >= switch
        back[i] = np.where(stay_better, np.arange(k), best_prev)
        delta = np.where(stay_better, delta, switch) + emission[i]
        delta -= delta.max()
    labels = np.zeros(m, dtype=np.int32)
    state = int(np.argmax(delta))
    for i in range(m - 1, -1, -1):
        labels[i] = state
        state = back[i, state]

    # Build split segments
    out: list[dict] = []
    i = 0
    while i < m:
        j = i
        while j + 1 < m and units[j + 1].seg_index == units[i].seg_index and labels[j + 1] == labels[i]:
            j += 1
        toks = units[i:j + 1]
        out.append({
            "start": toks[0].start,
            "end": max(toks[0].start + 0.05, toks[-1].end),
            "text": "".join(t.text for t in toks).strip(),
            "speaker": int(labels[i]),
            "source_segment": units[i].seg_index,
        })
        i = j + 1
    return canonical_speakers(out)


def canonical_speakers(segs: list[dict]) -> list[dict]:
    mapping: dict[int, int] = {}
    for s in segs:
        mapping.setdefault(s["speaker"], len(mapping) + 1)
        s["speaker"] = mapping[s["speaker"]]
    return segs


# ----------------------------------------------------------------------------- 3. correction

SPAN_PROMPT = """あなたは日本語ポッドキャストの音声認識結果の校正者です。
同じ音声を2つの音声認識エンジン(A と B)で書き起こし、食い違った箇所を [番号] で示します。
各箇所について、実際に話された可能性が高い方を "A" か "B" で選んでください。
判断材料: 前後の文脈・日本語として自然か・話題(収録の題名)。迷ったら "A"。
出力は JSON オブジェクトのみ: {"ID": {"番号": "A" または "B", ...}, ...}  説明は書かない。"""

TERMS_PROMPT = """あなたは日本語ポッドキャストの書き起こしの校正者です。
以下は音声認識の結果で、技術用語・製品名・サービス名・人名などがカタカナや誤った表記になっていることがあります。
本文に実際に出てくる語句のうち、正しい表記が確実に分かるものだけを、誤表記→正表記の対応表にしてください。
- 収録の題名や文脈から確実に判断できるものに限る。推測で人名を作らない
- 一般的な日本語の語(カタカナ語含む)は変更しない
- 出力は JSON オブジェクトのみ: {"誤表記": "正表記", ...}  説明は書かない。"""


def chat(model, tokenizer, content: str, prefill: str, max_tokens: int) -> str:
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    messages = [{"role": "user", "content": content}]
    try:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                               enable_thinking=False)
    except TypeError:
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    out = generate(model, tokenizer, prompt=prompt + prefill, max_tokens=max_tokens,
                   sampler=make_sampler(temp=0.0), verbose=False)
    return prefill + out


def parse_json_object(text: str) -> dict:
    text = re.sub(r"```(?:json)?", "", text)
    depth, end = 0, None
    for i, ch in enumerate(text):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    try:
        return json.loads(text[:end]) if end else {}
    except json.JSONDecodeError:
        return {}


STRIP_FOR_DIFF = re.compile(r"[\s、。，,.？?！!]")
NUMERALS = set("0123456789０１２３４５６７８９一二三四五六七八九十百千万〇")
FILLERS = {"えっと", "えと", "あの", "その", "ま", "まあ", "うん", "なんか", "え", "あ"}


def diff_spans(apple: str, whisper: str) -> list[dict]:
    """Replacement spans between the Apple text (kept as the base) and Whisper text.
    Pure insertions / deletions are ignored: Whisper drops fillers and its word window may bleed
    into the neighbouring utterance, so only 'both engines heard something different' is adjudicated."""
    a_chars = [(i, c) for i, c in enumerate(apple) if not STRIP_FOR_DIFF.match(c)]
    b = STRIP_FOR_DIFF.sub("", unicodedata.normalize("NFKC", whisper))
    a_str = "".join(unicodedata.normalize("NFKC", c) for _, c in a_chars)
    if not a_str or not b:
        return []
    spans = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a_str, b, autojunk=False).get_opcodes():
        if op != "replace":
            continue
        a_txt, b_txt = a_str[i1:i2], b[j1:j2]
        if a_txt in FILLERS or b_txt in FILLERS or any(f in a_txt for f in FILLERS if len(f) >= 2):
            continue
        # numeral style only (1 vs 一)
        if all(c in NUMERALS for c in a_txt + b_txt):
            continue
        # replacements of very different length are usually misalignments
        if max(len(a_txt), len(b_txt)) > 3 * min(len(a_txt), len(b_txt)) + 2:
            continue
        start, end = a_chars[i1][0], a_chars[i2 - 1][0] + 1
        spans.append({"start": start, "end": end, "a": apple[start:end], "b": b_txt})
    return spans


def apply_choices(apple: str, spans: list[dict], choices: dict) -> str:
    out, pos = [], 0
    for n, sp in enumerate(spans, 1):
        out.append(apple[pos:sp["start"]])
        out.append(sp["b"] if str(choices.get(str(n), "A")).upper() == "B" else sp["a"])
        pos = sp["end"]
    out.append(apple[pos:])
    return "".join(out)


def stage_correct(segments: list[dict], whisper: dict, work: Path, timer: Timer,
                  context_hint: str, batch_size: int = 8) -> tuple[list[dict], dict]:
    out = work / "corrected.json"
    if out.exists():
        data = load_json(out)
        return data["segments"], data["terms"]
    from mlx_lm import load

    words = whisper["words"]
    t_load = time.time()
    model, tokenizer = load(GEMMA_REPO)
    timer.record("gemma_load", time.time() - t_load)

    # --- (a) term table from the whole transcript, chunk by chunk
    t0 = time.time()
    full = "\n".join(s["text"] for s in segments)
    chunk = 2500
    terms: dict[str, str] = {}
    for ci in range(0, len(full), chunk):
        text = chat(model, tokenizer,
                    f"{TERMS_PROMPT}\n\n収録の題名: {context_hint}\n\n本文:\n{full[ci:ci + chunk]}",
                    prefill="{", max_tokens=400)
        for k, v in parse_json_object(text).items():
            k, v = str(k).strip(), str(v).strip()
            if len(k) >= 2 and k != v and k in full and v and k not in terms:
                terms[k] = v
    timer.record("gemma_terms", time.time() - t0)
    print(f"  gemma terms: {terms}", flush=True)

    # --- (b) span adjudication between Apple and Whisper
    t0 = time.time()
    items = []
    for i, s in enumerate(segments):
        wt = whisper_text_between(words, s["start"] + TOKEN_TIME_SHIFT, s["end"] + TOKEN_TIME_SHIFT)
        items.append({"id": i, "apple": s["text"], "whisper": wt, "spans": diff_spans(s["text"], wt)})
    todo = [it for it in items if it["spans"]]
    choices: dict[int, dict] = {}
    for bi in range(0, len(todo), batch_size):
        batch = todo[bi:bi + batch_size]
        lines = [SPAN_PROMPT, "", f"収録の題名: {context_hint}", ""]
        for it in batch:
            marked, pos = [], 0
            for n, sp in enumerate(it["spans"], 1):
                marked.append(it["apple"][pos:sp["start"]] + f"[{n}]")
                pos = sp["end"]
            marked.append(it["apple"][pos:])
            prev = segments[it["id"] - 1]["text"][-30:] if it["id"] > 0 else ""
            lines.append(f"ID {it['id']}")
            if prev:
                lines.append(f"  直前: {prev}")
            lines.append(f"  文: {''.join(marked)}")
            for n, sp in enumerate(it["spans"], 1):
                lines.append(f"  [{n}] A「{sp['a']}」 / B「{sp['b']}」")
        text = chat(model, tokenizer, "\n".join(lines), prefill="{", max_tokens=60 * len(batch) + 40)
        parsed = parse_json_object(text)
        for it in batch:
            c = parsed.get(str(it["id"]))
            choices[it["id"]] = c if isinstance(c, dict) else {}
        print(f"  gemma spans {min(bi + batch_size, len(todo))}/{len(todo)} ({time.time() - t0:.0f}s)", flush=True)
    timer.record("gemma_spans", time.time() - t0)

    result = []
    for it, s in zip(items, segments):
        chosen = apply_choices(it["apple"], it["spans"], choices.get(it["id"], {}))
        final = chosen
        applied_terms = []
        for k, v in terms.items():
            if k in final:
                final = final.replace(k, v)
                applied_terms.append([k, v])
        span_info = [{**sp, "choice": str(choices.get(it["id"], {}).get(str(n), "A")).upper()}
                     for n, sp in enumerate(it["spans"], 1)]
        result.append({**s, "apple": it["apple"], "whisper": it["whisper"], "corrected": final,
                       "spans": span_info, "terms": applied_terms,
                       "changed": final != it["apple"]})
    save_json(out, {"segments": result, "terms": terms})
    return result, terms


# ----------------------------------------------------------------------------- 4. report

def speaker_at(segs: list[dict], t: float, key_start="start", key_end="end", key_spk="speaker"):
    for s in segs:
        if s[key_start] <= t < s[key_end]:
            return s[key_spk]
    return None


def best_mapping(a: list, b: list) -> dict:
    """Map labels of b onto a maximizing agreement (2-3 speakers: brute force)."""
    from itertools import permutations
    la = sorted({x for x in a if x is not None})
    lb = sorted({x for x in b if x is not None})
    best, best_map = -1, {}
    for perm in permutations(la, len(lb)) if len(la) >= len(lb) else []:
        mp = dict(zip(lb, perm))
        score = sum(1 for x, y in zip(a, b) if x is not None and y is not None and mp[y] == x)
        if score > best:
            best, best_map = score, mp
    return best_map or {x: x for x in lb}


def stage_report(baseline: list[dict], refined: list[dict], whisper: dict, work: Path, media: Path) -> dict:
    timings = load_json(work / "timings.json")
    base = [{"start": s["startTime"], "end": s["endTime"], "speaker": s["speakerID"], "text": s["text"]} for s in baseline]

    # speaker agreement on a 0.1 s grid over speech covered by refined segments
    grid_a, grid_b = [], []
    for s in refined:
        t = s["start"]
        while t < s["end"]:
            grid_a.append(speaker_at(base, t))
            grid_b.append(s["speaker"])
            t += 0.1
    mp = best_mapping(grid_a, grid_b)
    for s in refined:
        s["speaker_mapped"] = mp.get(s["speaker"], s["speaker"])
        mid = (s["start"] + s["end"]) / 2
        s["speaker_baseline"] = speaker_at(base, mid)
    agree = sum(1 for x, y in zip(grid_a, grid_b) if x is not None and mp.get(y) == x)
    total = sum(1 for x in grid_a if x is not None)

    report = {
        "media": media.name,
        "timings": timings,
        "speaker_agreement": round(agree / max(1, total), 4),
        "baseline": base,
        "refined": refined,
        "whisper_segments": whisper["segments"],
    }
    save_json(work / "report.json", report)
    return report


# ----------------------------------------------------------------------------- main

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", type=Path, required=True, help="Apple STT segments JSON (--speakers 0 --json-out)")
    ap.add_argument("--baseline", type=Path, required=True, help="current app diarization JSON (for comparison)")
    ap.add_argument("--media", type=Path, required=True)
    ap.add_argument("--work-dir", type=Path, required=True)
    ap.add_argument("--embedding", choices=list(EMBEDDING_MODELS), default="eres2net")
    ap.add_argument("--speakers", type=int, default=-1, help="-1 = auto")
    ap.add_argument("--stages", default="whisper,speakers,correct,report")
    args = ap.parse_args()

    work = args.work_dir
    work.mkdir(parents=True, exist_ok=True)
    timer = Timer(work)
    stages = set(args.stages.split(","))
    raw = load_json(args.raw)
    wav = decode_audio(args.media, work)

    whisper = stage_whisper(wav, work, timer) if "whisper" in stages or "correct" in stages or "report" in stages else None
    if whisper:
        print(f"whisper: {len(whisper['words'])} words")

    refined = None
    if stages & {"speakers", "correct", "report"}:
        neural = stage_neural_diarization(wav, raw, work, timer, args.embedding, args.speakers)
        t0 = time.time()
        refined = assign_speakers_to_tokens(raw, neural)
        timer.record("token_assignment", time.time() - t0)
        print(f"neural diarization: {neural['k']} speakers ({len(neural['windows'])} windows), {len(refined)} segments")
        save_json(work / "speakers.json", refined)

    if refined is not None and stages & {"correct", "report"}:
        hint = args.media.stem
        refined, terms = stage_correct(refined, whisper, work, timer, context_hint=hint)
        print(f"gemma: {sum(1 for s in refined if s['changed'])} segments changed, terms={terms}")

    if "report" in stages and refined is not None:
        rep = stage_report(load_json(args.baseline), refined, whisper, work, args.media)
        rep["terms"] = terms
        save_json(work / "report.json", rep)
        print(f"speaker agreement baseline vs neural: {rep['speaker_agreement']:.3f}")
        print("timings:", rep["timings"])


if __name__ == "__main__":
    main()
