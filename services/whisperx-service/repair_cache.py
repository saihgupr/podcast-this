#!/usr/bin/env python3
"""
repair_cache.py

Fast cache repair utility for podcast-this diarization cache files.
Re-evaluates segment language labels using Spanish/English stopword analysis and
speaker turn context inheritance without re-running audio neural networks.
"""

import os
import sys
import json
import re
import argparse
from typing import Dict, List, Optional, Set, Tuple

# Common Spanish stopwords and characteristic function words
ES_STOPWORDS: Set[str] = {
    "a", "al", "del", "el", "la", "los", "las", "de", "que", "y", "en", "un", "una", "unos", "unas", "por", "para",
    "con", "no", "es", "lo", "como", "su", "sus", "mas", "más", "pero",
    "le", "les", "ya", "o", "fue", "este", "esta", "estos", "estas", "ha", "han",
    "si", "sí", "porque", "cuando", "muy", "sin", "sobre", "tambien", "también",
    "me", "te", "se", "nos", "hasta", "hay", "donde", "quien", "quienes", "desde",
    "todo", "toda", "todos", "todas", "durante", "uno", "ni", "contra", "otros",
    "otro", "otra", "otras", "ese", "esa", "esos", "esas", "eso", "ante", "ellos",
    "ellas", "esto", "mi", "mí", "mis", "antes", "algunos", "algunas", "algo",
    "alguien", "que", "qué", "yo", "tu", "tú", "él", "ella", "tanto", "tanta",
    "mucho", "mucha", "muchos", "muchas", "nada", "nadie", "cual", "cuales", "poco", "poca",
    "pocos", "pocas", "estar", "estoy", "esta", "está", "estan", "están", "somos",
    "era", "eran", "sido", "tiene", "tienen", "tenemos", "puede", "pueden", "puedo", "podemos",
    "habla", "hablamos", "decir", "dijo", "dices", "bueno", "claro", "bien", "hola", "gracias",
    "adios", "adiós", "verdad", "verdadero", "mundo", "vida", "ahora", "siempre", "nunca",
    "despues", "después", "entonces", "asi", "así", "aqui", "aquí", "alli", "allí",
    "veces", "saber", "sé", "sabe", "sabemos", "parece", "momento", "tiempo",
    "dentro", "fuera", "hacer", "hace", "hacen", "siento", "siente", "sentimiento",
    "entre", "hacia", "mismo", "misma", "tal", "acá", "aca"
}

# Common English stopwords
EN_STOPWORDS: Set[str] = {
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for",
    "not", "on", "with", "he", "as", "you", "do", "at", "this", "but", "his",
    "by", "from", "they", "we", "say", "her", "she", "or", "an", "will", "my",
    "one", "all", "would", "there", "their", "what", "so", "up", "out", "if",
    "about", "who", "get", "which", "go", "me", "when", "make", "can", "like",
    "time", "no", "just", "him", "know", "take", "people", "into", "year", "your",
    "good", "some", "could", "them", "see", "other", "than", "then", "now", "look",
    "only", "come", "its", "over", "think", "also", "back", "after", "use", "two",
    "how", "our", "work", "first", "well", "way", "even", "new", "want", "because",
    "any", "these", "give", "day", "most", "us", "are", "is", "was", "were", "been"
}

def clean_words(text: str) -> List[str]:
    """Tokenizes text into lowercase alpha words."""
    if not text:
        return []
    # Strip punctuation and keep alphanumeric words
    tokens = re.findall(r"\b[a-zA-ZáéíóúüñÁÉÍÓÚÜÑ']+\b", text.lower())
    return [t for t in tokens if len(t) > 0]

def score_text_language(text: str) -> Tuple[Optional[str], int, int]:
    """
    Scores text against ES and EN stopword lists.
    Returns (detected_lang, es_matches, en_matches).
    """
    words = clean_words(text)
    if not words:
        return None, 0, 0

    es_matches = sum(1 for w in words if w in ES_STOPWORDS)
    en_matches = sum(1 for w in words if w in EN_STOPWORDS)

    # Check for Spanish-specific accented characters / ñ
    has_spanish_diacritics = any(c in "áéíóúñÁÉÍÓÚÑ" for c in text)
    if has_spanish_diacritics:
        es_matches += 1

    if es_matches > en_matches:
        return "es", es_matches, en_matches
    elif en_matches > es_matches:
        return "en", es_matches, en_matches
    return None, es_matches, en_matches

def repair_cache_data(data: dict) -> Tuple[dict, dict]:
    """
    Repairs a diarization dictionary in-place.
    Returns (repaired_data, stats).
    """
    segments = data.get("segments", [])
    if not segments:
        return data, {"total": 0, "changed": 0}

    # Pass 1: Stopword-based classification on segment text
    # Also aggregate speaker stats to determine dominant language
    speaker_stats: Dict[str, Dict[str, float]] = {}

    for seg in segments:
        spk = seg.get("speaker_id") or "UNKNOWN"
        dur = max(0.0, float(seg.get("end", 0.0)) - float(seg.get("start", 0.0)))
        current_lang = (seg.get("language") or "en").lower()
        text = (seg.get("text") or "").strip()

        # Check stopwords
        text_lang, es_cnt, en_cnt = score_text_language(text)

        assigned_lang = current_lang
        # If text clearly contains Spanish stopwords
        if text_lang == "es" and es_cnt >= 1:
            assigned_lang = "es"
        # If current was flagged as spurious hallucination (gl, el, da, cy, etc.) and text is Spanish
        elif current_lang in ["gl", "el", "da", "cy", "gd", "la", "pt", "it"] and (text_lang == "es" or es_cnt >= 1):
            assigned_lang = "es"

        seg["_temp_lang"] = assigned_lang

        if spk not in speaker_stats:
            speaker_stats[spk] = {"total_dur": 0.0, "es_dur": 0.0, "en_dur": 0.0, "es_turns": 0, "en_turns": 0, "total_turns": 0}
        speaker_stats[spk]["total_dur"] += dur
        speaker_stats[spk]["total_turns"] += 1
        if assigned_lang == "es":
            speaker_stats[spk]["es_dur"] += dur
            speaker_stats[spk]["es_turns"] += 1
        elif assigned_lang == "en":
            speaker_stats[spk]["en_dur"] += dur
            speaker_stats[spk]["en_turns"] += 1

    # Determine speaker dominant language
    speaker_dominant: Dict[str, str] = {}
    for spk, stats in speaker_stats.items():
        total_dur = stats["total_dur"]
        if total_dur > 0:
            es_ratio = stats["es_dur"] / total_dur
            if es_ratio >= 0.65 or (stats["es_turns"] >= 10 and stats["es_turns"] / stats["total_turns"] >= 0.60):
                speaker_dominant[spk] = "es"
            elif (stats["en_dur"] / total_dur) >= 0.70:
                speaker_dominant[spk] = "en"

    # Pass 2: Speaker context inheritance & neighbor smoothing
    changed_count = 0
    lang_durations: Dict[str, float] = {}

    for idx, seg in enumerate(segments):
        spk = seg.get("speaker_id") or "UNKNOWN"
        dur = max(0.0, float(seg.get("end", 0.0)) - float(seg.get("start", 0.0)))
        orig_lang = (seg.get("language") or "en").lower()
        temp_lang = seg.pop("_temp_lang", orig_lang)
        text = (seg.get("text") or "").strip()

        final_lang = temp_lang

        # If the speaker is dominantly Spanish
        if speaker_dominant.get(spk) == "es":
            # If segment has no strong English stopwords, inherit Spanish
            text_lang, es_cnt, en_cnt = score_text_language(text)
            if text_lang != "en" or en_cnt == 0:
                final_lang = "es"
            elif en_cnt <= 1 and es_cnt >= 1:
                final_lang = "es"
            elif not text: # untranscribed segment for a Spanish speaker
                final_lang = "es"

        # Suppress known Whisper low-resource acoustic misattributions if text is Spanish
        if final_lang in ["gl", "pt", "it", "cy", "gd", "la", "el", "da"]:
            if speaker_dominant.get(spk) == "es" or score_text_language(text)[0] == "es":
                final_lang = "es"

        if final_lang != orig_lang:
            changed_count += 1
            seg["language"] = final_lang
        else:
            seg["language"] = final_lang

        lang_durations[final_lang] = lang_durations.get(final_lang, 0.0) + dur

    # Update detected_languages in cache
    detected_languages = []
    total_audio_dur = sum(lang_durations.values())
    if total_audio_dur > 0:
        for l, d_dur in sorted(lang_durations.items(), key=lambda x: x[1], reverse=True):
            if (d_dur / total_audio_dur) >= 0.02 or d_dur >= 8.0:
                if l not in ["cy", "gd", "la", "gl", "el"] or (d_dur / total_audio_dur) >= 0.10:
                    detected_languages.append(l)
    if not detected_languages:
        detected_languages = ["en"]
    data["detected_languages"] = detected_languages

    # Update speaker profile metadata
    if "speakers" in data and isinstance(data["speakers"], list):
        for spk_prof in data["speakers"]:
            spk_id = spk_prof.get("id")
            if spk_id in speaker_dominant:
                dom = speaker_dominant[spk_id]
                spk_prof["dominant_language"] = dom
                spk_prof["is_non_english"] = (dom != "en")

    return data, {
        "total": len(segments),
        "changed": changed_count,
        "speaker_dominant": speaker_dominant,
        "detected_languages": detected_languages
    }

def process_file(filepath: str) -> bool:
    print(f"[*] Processing {filepath}...")
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)

        repaired_data, stats = repair_cache_data(data)

        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(repaired_data, f, indent=2, ensure_ascii=False)

        print(f"    [+] Successfully repaired: {stats['changed']} of {stats['total']} segments changed.")
        print(f"        Dominant speakers: {stats['speaker_dominant']}")
        print(f"        Detected languages: {stats['detected_languages']}")
        return True
    except Exception as e:
        print(f"    [-] Error processing {filepath}: {e}", file=sys.stderr)
        return False

def main():
    parser = argparse.ArgumentParser(description="Repair whisperx-service diarization cache segment language labels")
    parser.add_argument("--video-id", type=str, help="Specific video_id to repair (e.g. t2nptZC_HeI)")
    parser.add_argument("--cache-dir", type=str, default=os.path.join(os.path.dirname(__file__), "cache"), help="Path to cache directory")
    parser.add_argument("--all", action="store_true", help="Repair all JSON cache files in cache directory")
    args = parser.parse_args()

    cache_dir = os.path.abspath(args.cache_dir)
    if not os.path.exists(cache_dir):
        print(f"[-] Cache directory does not exist: {cache_dir}", file=sys.stderr)
        sys.exit(1)

    if args.video_id:
        target = os.path.join(cache_dir, f"{args.video_id}.json")
        if not os.path.exists(target):
            print(f"[-] Cache file not found: {target}", file=sys.stderr)
            sys.exit(1)
        success = process_file(target)
        sys.exit(0 if success else 1)
    elif args.all:
        json_files = [os.path.join(cache_dir, f) for f in os.listdir(cache_dir) if f.endswith(".json")]
        print(f"[*] Found {len(json_files)} cache files in {cache_dir}")
        count_ok = 0
        for fpath in sorted(json_files):
            if process_file(fpath):
                count_ok += 1
        print(f"[*] Completed repair of {count_ok}/{len(json_files)} files.")
    else:
        parser.print_help()
        sys.exit(1)

if __name__ == "__main__":
    main()
