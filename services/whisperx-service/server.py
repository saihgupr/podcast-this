#!/usr/bin/env python3
"""
WhisperX Speaker Diarization Microservice for PodcastThis
Accepts audio file uploads or URLs, performs WhisperX speech transcription
and PyAnnote speaker diarization, caches results to disk, and tracks job status.
"""

import os
import sys

# Ensure ffmpeg and standard binaries (Homebrew, MacPorts, ~/.local/bin) are accessible in PATH
_standard_bin_dirs = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    os.path.expanduser("~/.local/bin"),
]
_current_paths = os.environ.get("PATH", "").split(os.path.pathsep)
for _d in reversed(_standard_bin_dirs):
    if _d not in _current_paths and os.path.exists(_d):
        _current_paths.insert(0, _d)
os.environ["PATH"] = os.path.pathsep.join(_current_paths)

import json
import uuid
import shutil
import tempfile
import logging
import asyncio
import time
import signal
from concurrent.futures import ThreadPoolExecutor
from typing import Optional, List, Dict, Any, Tuple
from pydantic import BaseModel
from fastapi import FastAPI, File, UploadFile, Form, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("whisperx-service")

app = FastAPI(
    title="PodcastThis WhisperX Diarization Service",
    description="Local computer service to transcribe and diarize speakers for PodcastThis episodes.",
    version="1.1.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Auto-load .env file if present in service directory
SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(SERVICE_DIR, "cache")
os.makedirs(CACHE_DIR, exist_ok=True)

# Store NLTK data in hidden standard cache (~/.cache/nltk_data) instead of home directory
nltk_cache_dir = os.path.expanduser("~/.cache/nltk_data")
os.makedirs(nltk_cache_dir, exist_ok=True)
os.environ["NLTK_DATA"] = nltk_cache_dir
try:
    import nltk
    nltk.data.path.insert(0, nltk_cache_dir)
except ImportError:
    pass

env_path = os.path.join(SERVICE_DIR, ".env")
if os.path.exists(env_path):
    with open(env_path, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, val = line.split("=", 1)
                os.environ[key.strip()] = val.strip().strip('"').strip("'")

# Idle auto-shutdown configuration (default 30 minutes, set 0 to disable)
IDLE_TIMEOUT_MINUTES = int(os.environ.get("IDLE_TIMEOUT_MINUTES", "30"))
LAST_ACTIVITY_TIME = time.time()

# Global model cache and thread pool
WHISPER_MODEL = None
WHISPER_MODEL_NAME = os.environ.get("WHISPER_MODEL_NAME", "small")
DIARIZATION_PIPELINE = None
DEVICE = "cuda" if os.environ.get("CUDA_VISIBLE_DEVICES") else ("mps" if sys.platform == "darwin" else "cpu")
HF_TOKEN = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")

EXECUTOR = ThreadPoolExecutor(max_workers=1)
ACTIVE_JOBS: Dict[str, Dict[str, Any]] = {}

# macOS Native Menu Bar Status Item integration
HAS_PYOBJC = False
if sys.platform == "darwin":
    try:
        import AppKit
        import Foundation
        from PyObjCTools import AppHelper, MachSignals
        HAS_PYOBJC = True
    except ImportError:
        HAS_PYOBJC = False

if HAS_PYOBJC:
    class MenuBarDelegate(Foundation.NSObject):
        def menuNeedsUpdate_(self, menu):
            if self.manager:
                self.manager.populate_menu(menu)

        def tick_(self, timer):
            if self.manager:
                self.manager.on_timer_tick()

        def openHealth_(self, sender):
            try:
                port = int(os.environ.get("PORT", 8000))
                url = Foundation.NSURL.URLWithString_(f"http://localhost:{port}/health")
                AppKit.NSWorkspace.sharedWorkspace().openURL_(url)
            except Exception as e:
                logger.warning(f"Could not open health URL: {e}")

        def openCacheFolder_(self, sender):
            try:
                AppKit.NSWorkspace.sharedWorkspace().openFile_(CACHE_DIR)
            except Exception as e:
                logger.warning(f"Could not open cache directory: {e}")

        def quitService_(self, sender):
            logger.info("[*] Quit requested from macOS menu bar item.")
            os.kill(os.getpid(), signal.SIGINT)

    class StatusBarManager:
        def __init__(self):
            self.status_item = None
            self.menu = None
            self.delegate = None
            self.timer = None
            self.is_active = False

        def setup(self):
            try:
                app_inst = AppKit.NSApplication.sharedApplication()
                app_inst.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)

                self.delegate = MenuBarDelegate.alloc().init()
                self.delegate.manager = self

                self.status_item = AppKit.NSStatusBar.systemStatusBar().statusItemWithLength_(
                    AppKit.NSVariableStatusItemLength
                )
                self.status_item.setVisible_(False)

                self.menu = AppKit.NSMenu.alloc().init()
                self.menu.setDelegate_(self.delegate)
                self.status_item.setMenu_(self.menu)

                # Add timer to common modes so it updates during user menu interaction
                self.timer = Foundation.NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
                    1.0, self.delegate, "tick:", None, True
                )
                Foundation.NSRunLoop.currentRunLoop().addTimer_forMode_(
                    self.timer, Foundation.NSRunLoopCommonModes
                )
                logger.info("[*] Native macOS menu bar status item initialized (hidden until jobs run).")
            except Exception as e:
                logger.warning(f"Failed to initialize macOS status bar item: {e}")

        def on_timer_tick(self):
            self.refresh_state()

        def refresh_state(self):
            """Called on the AppKit main thread to update visibility and button title."""
            if not self.status_item:
                return

            try:
                active_jobs = [
                    (vid, j) for vid, j in ACTIVE_JOBS.items()
                    if j.get("status") == "processing"
                ]

                if not active_jobs:
                    if self.is_active or self.status_item.isVisible():
                        self.status_item.setVisible_(False)
                        self.is_active = False
                    return

                self.is_active = True
                if not self.status_item.isVisible():
                    self.status_item.setVisible_(True)

                button = self.status_item.button()
                if button:
                    if len(active_jobs) == 1:
                        step = active_jobs[0][1].get("step", "Processing...")
                        short_step = self._format_short_step(step)
                        button.setTitle_(short_step)
                    else:
                        button.setTitle_(f"Processing ({len(active_jobs)} jobs)...")
            except Exception as e:
                logger.debug(f"Error refreshing status bar state: {e}")

        def _format_short_step(self, step: str) -> str:
            s = step.lower()
            if "transcrib" in s:
                return "Transcribing..."
            elif "align" in s:
                return "Aligning..."
            elif "diariz" in s:
                return "Diarizing..."
            elif "label" in s:
                return "Labeling..."
            elif "language" in s:
                return "Detecting Lang..."
            elif "upload" in s or "initializ" in s:
                return "Initializing..."
            elif len(step) > 22:
                return step[:19] + "..."
            return step

        def populate_menu(self, menu):
            menu.removeAllItems()

            bold_font = AppKit.NSFont.boldSystemFontOfSize_(AppKit.NSFont.systemFontSize())

            # 1. Header
            header = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "🎙️ PodcastThis Diarization Engine", None, ""
            )
            header.setEnabled_(False)
            if hasattr(header, "setFont_"):
                header.setFont_(bold_font)
            menu.addItem_(header)
            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            # 2. Active Jobs
            active_jobs = [
                (vid, j) for vid, j in ACTIVE_JOBS.items()
                if j.get("status") == "processing"
            ]

            if not active_jobs:
                idle_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                    "Idle — No active jobs", None, ""
                )
                idle_item.setEnabled_(False)
                menu.addItem_(idle_item)
            else:
                for i, (vid, job) in enumerate(active_jobs):
                    if i > 0:
                        menu.addItem_(AppKit.NSMenuItem.separatorItem())

                    raw_title = job.get("title") or f"Episode {vid[:8]}"
                    clean_title = raw_title[:45] + ("..." if len(raw_title) > 45 else "")
                    step = job.get("step") or "Processing..."
                    start_time = job.get("start_time") or time.time()
                    elapsed_sec = int(time.time() - start_time)
                    elapsed_str = f"{elapsed_sec // 60:02d}:{elapsed_sec % 60:02d}"

                    # Episode Title
                    title_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                        f"📻 {clean_title}", None, ""
                    )
                    title_item.setEnabled_(False)
                    if hasattr(title_item, "setFont_"):
                        title_item.setFont_(bold_font)
                    menu.addItem_(title_item)

                    # Stage
                    stage_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                        f"    ⚡ Stage: {step}", None, ""
                    )
                    stage_item.setEnabled_(False)
                    menu.addItem_(stage_item)

                    # Elapsed time
                    time_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                        f"    ⏱️ Elapsed: {elapsed_str}", None, ""
                    )
                    time_item.setEnabled_(False)
                    menu.addItem_(time_item)

                    # Job ID
                    id_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                        f"    🆔 ID: {vid[:12]}...", None, ""
                    )
                    id_item.setEnabled_(False)
                    menu.addItem_(id_item)

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            # 3. Server info
            port = int(os.environ.get("PORT", 8000))
            server_info = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                f"● Server Online (Port {port}, Device: {DEVICE})", None, ""
            )
            server_info.setEnabled_(False)
            menu.addItem_(server_info)

            # Quick Actions
            health_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Open Service Health / Status...", "openHealth:", ""
            )
            health_item.setTarget_(self.delegate)
            menu.addItem_(health_item)

            cache_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Open Cache Directory in Finder...", "openCacheFolder:", ""
            )
            cache_item.setTarget_(self.delegate)
            menu.addItem_(cache_item)

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            # Quit Action
            quit_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Quit WhisperX Service", "quitService:", "q"
            )
            quit_item.setTarget_(self.delegate)
            menu.addItem_(quit_item)

        def trigger_refresh(self):
            """Thread-safe call from worker threads to immediately refresh UI."""
            if HAS_PYOBJC and self.status_item:
                AppHelper.callAfter(self.refresh_state)

else:
    class StatusBarManager:
        def setup(self):
            pass
        def trigger_refresh(self):
            pass

STATUS_BAR_MANAGER: Optional[StatusBarManager] = None

def notify_menubar_updated():
    """Notify the macOS menu bar manager of state changes."""
    global STATUS_BAR_MANAGER
    if STATUS_BAR_MANAGER is not None:
        STATUS_BAR_MANAGER.trigger_refresh()

def update_job_step(video_id: str, step: str):
    """Update pipeline step for active job and notify menu bar."""
    if video_id in ACTIVE_JOBS:
        ACTIVE_JOBS[video_id]["step"] = step
    notify_menubar_updated()

@app.middleware("http")
async def track_activity_middleware(request, call_next):
    """Update last activity timestamp on any incoming HTTP request."""
    global LAST_ACTIVITY_TIME
    LAST_ACTIVITY_TIME = time.time()
    return await call_next(request)

@app.on_event("startup")
async def start_idle_watcher():
    """Background task to automatically stop the server when idle for IDLE_TIMEOUT_MINUTES."""
    if IDLE_TIMEOUT_MINUTES <= 0:
        logger.info("[*] Idle auto-shutdown disabled (IDLE_TIMEOUT_MINUTES=0). Server will run indefinitely.")
        return

    logger.info(f"[*] Idle auto-shutdown enabled: server will stop after {IDLE_TIMEOUT_MINUTES} minutes of inactivity.")

    async def _idle_check_loop():
        global LAST_ACTIVITY_TIME
        while True:
            await asyncio.sleep(15)
            # If any job is actively processing, keep updating activity time
            has_active_jobs = any(
                j.get("status") == "processing" for j in ACTIVE_JOBS.values()
            )
            if has_active_jobs:
                LAST_ACTIVITY_TIME = time.time()
                continue

            idle_seconds = time.time() - LAST_ACTIVITY_TIME
            if idle_seconds >= (IDLE_TIMEOUT_MINUTES * 60):
                logger.info(
                    f"[*] Server idle for {int(idle_seconds // 60)} minutes with no active jobs. Shutting down automatically..."
                )
                # Send SIGINT to own process to shut down cleanly
                os.kill(os.getpid(), signal.SIGINT)
                break

    asyncio.create_task(_idle_check_loop())


class SpeakerProfile(BaseModel):
    id: str
    default_name: str
    is_skipped: bool = False
    total_duration: float
    sample_text: Optional[str] = None
    first_timestamp: Optional[float] = None
    is_non_english: Optional[bool] = False
    dominant_language: Optional[str] = None

class SpeakerSegment(BaseModel):
    speaker_id: str
    start: float
    end: float
    language: Optional[str] = "en"
    text: Optional[str] = None

class DiarizationResponse(BaseModel):
    video_id: Optional[str] = None
    speakers: List[SpeakerProfile]
    segments: List[SpeakerSegment]
    analyzed_date: str
    detected_languages: Optional[List[str]] = None
    filter_english_only: Optional[bool] = False

def load_models():
    """Lazy load WhisperX model and PyAnnote Diarization pipeline with multi-core optimization."""
    global WHISPER_MODEL, DIARIZATION_PIPELINE
    import whisperx
    import torch

    num_threads = max(4, os.cpu_count() or 8)
    torch.set_num_threads(num_threads)
    logger.info(f"Using {num_threads} CPU threads for PyTorch computation.")

    # WhisperX transcription model
    device = "cpu"
    compute_type = "int8"
    
    if WHISPER_MODEL is None:
        model_name = WHISPER_MODEL_NAME
        logger.info(f"Loading WhisperX model ({model_name}) on {device} with {num_threads} threads (condition_on_previous_text=False)...")
        asr_options = {
            "condition_on_previous_text": False,
            "repetition_penalty": 1.2,
            "no_repeat_ngram_size": 3,
            "temperatures": [0.0, 0.2, 0.4],
        }
        try:
            WHISPER_MODEL = whisperx.load_model(model_name, device, compute_type=compute_type, threads=num_threads, asr_options=asr_options)
        except Exception as e:
            logger.warning(f"Failed loading {model_name} with compute_type={compute_type}, falling back to default: {e}")
            WHISPER_MODEL = whisperx.load_model(model_name, device, asr_options=asr_options)

    if DIARIZATION_PIPELINE is None:
        logger.info("Loading PyAnnote Diarization Pipeline...")
        token = HF_TOKEN or os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
        if not token:
            logger.warning("HF_TOKEN is not set. PyAnnote model download may fail without Hugging Face credentials.")
        try:
            from whisperx.diarize import DiarizationPipeline
            try:
                DIARIZATION_PIPELINE = DiarizationPipeline(token=token, device=device)
            except TypeError:
                DIARIZATION_PIPELINE = DiarizationPipeline(use_auth_token=token, device=device)
        except Exception as e:
            logger.error(f"Error initializing DiarizationPipeline: {e}")
            raise e

def get_cached_result(video_id: str) -> Optional[DiarizationResponse]:
    """Check if result is already cached on disk."""
    if not video_id:
        return None
    cache_file = os.path.join(CACHE_DIR, f"{video_id}.json")
    if os.path.exists(cache_file):
        try:
            with open(cache_file, "r") as f:
                data = json.load(f)
                logger.info(f"Returning cached diarization result for video_id: {video_id}")
                return DiarizationResponse(**data)
        except Exception as e:
            logger.warning(f"Failed to read cache file {cache_file}: {e}")
    return None

def save_cached_result(video_id: str, response: DiarizationResponse):
    """Save result to disk cache."""
    if not video_id:
        return
    cache_file = os.path.join(CACHE_DIR, f"{video_id}.json")
    try:
        with open(cache_file, "w") as f:
            f.write(response.model_dump_json(indent=2))
        logger.info(f"Cached diarization result saved to: {cache_file}")
    except Exception as e:
        logger.warning(f"Failed to write cache file {cache_file}: {e}")

def notify_mac_diarization_start(video_id: str, title: Optional[str] = None):
    """Post non-persistent native macOS Notification Center banner when diarization starts."""
    import subprocess
    import shutil
    import os

    display_title = title.strip() if title and title.strip() else ""
    if display_title:
        msg = f"Analyzing speakers for \"{display_title}\"..."
    else:
        msg = "Analyzing speakers for episode..."

    icon_png = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../ios-app/Icon.png"))

    notificli_bin = shutil.which("notificli") or "/opt/homebrew/bin/notificli"
    if os.path.exists(notificli_bin):
        # 1. Try with custom PodcastThis icon variant (non-persistent: omitting --persistent)
        try:
            res = subprocess.run([
                notificli_bin,
                "-icon", "PodcastThis",
                "--title", "PodcastThis WhisperX",
                "--subtitle", "Speaker Analysis Started",
                "--message", msg,
                "--image", icon_png
            ], capture_output=True, text=True, timeout=3)
            if res.returncode == 0:
                logger.info(f"[{video_id}] Posted start macOS notification banner via NotifiCLI (-icon PodcastThis)")
                return
        except Exception:
            pass

        # 2. Fall back to standard NotifiCLI with PodcastThis image
        try:
            res2 = subprocess.run([
                notificli_bin,
                "--title", "PodcastThis WhisperX",
                "--subtitle", "Speaker Analysis Started",
                "--message", msg,
                "--image", icon_png
            ], capture_output=True, text=True, timeout=3)
            if res2.returncode == 0:
                logger.info(f"[{video_id}] Posted start macOS notification banner via NotifiCLI (--image)")
                return
        except Exception:
            pass

    # 3. Fallback to osascript
    safe_msg = msg.replace('"', '\\"')
    script = f'display notification "{safe_msg}" with title "PodcastThis WhisperX" subtitle "Speaker Analysis Started"'
    try:
        subprocess.run(["osascript", "-e", script], check=False)
        logger.info(f"[{video_id}] Posted start macOS notification banner via osascript")
    except Exception as e:
        logger.warning(f"[{video_id}] Could not post start macOS notification: {e}")

def _format_duration(seconds: float) -> str:
    """Format duration into human readable string like '1m 24s' or '45s' or '1h 12m'."""
    total_seconds = int(round(seconds))
    if total_seconds < 60:
        return f"{total_seconds}s"
    minutes = total_seconds // 60
    rem_seconds = total_seconds % 60
    if minutes < 60:
        if rem_seconds > 0:
            return f"{minutes}m {rem_seconds}s"
        return f"{minutes}m"
    hours = minutes // 60
    rem_minutes = minutes % 60
    if rem_minutes > 0:
        return f"{hours}h {rem_minutes}m"
def _score_and_extract_speaker_sample(candidates: List[str]) -> Optional[str]:
    """
    Select the most descriptive and representative quote for a speaker from a list of turns.
    Prioritizes self-introductions, greetings, and substantive complete thoughts over short filler.
    """
    import re

    if not candidates:
        return None

    # Filter out empty or whitespace-only candidates
    valid_candidates = [c.strip() for c in candidates if c and len(c.strip()) >= 3]
    if not valid_candidates:
        return candidates[0].strip() if candidates else None

    # Negative words indicating pure filler / murmurs
    filler_set = {"yeah", "yes", "okay", "no", "sure", "yep", "right", "uh", "um", "mhm", "ah", "thanks", "thank you"}

    def candidate_score(text: str) -> float:
        score = 0.0
        lower = text.lower()
        words = lower.split()

        # Heavily penalize short filler utterances
        if len(words) <= 2 and any(w.strip(".,!?") in filler_set for w in words):
            return -50.0

        # Reward self-introductions or name mentions
        if re.search(r"\b(i'm|i am|my name is|this is|call me)\s+[A-Z][a-z]+", text):
            score += 100.0
        elif re.search(r"\b(hello|welcome|hi|greetings)\b", lower):
            score += 30.0

        # Reward substantive length (ideal quote is ~40-100 characters)
        length = len(text)
        if 35 <= length <= 130:
            score += 40.0
        elif length > 130:
            score += 25.0
        elif length >= 15:
            score += 15.0

        # Reward sentence ending punctuation
        if text.endswith((".", "!", "?")):
            score += 5.0

        return score

    best_candidate = max(valid_candidates, key=candidate_score)
    # Truncate if candidate is very long
    if len(best_candidate) > 130:
        truncated = best_candidate[:127]
        # Try cutting at last word boundary
        last_space = truncated.rfind(" ")
        if last_space > 80:
            truncated = truncated[:last_space]
        return truncated + "..."
    return best_candidate

# Common Spanish stopwords and characteristic function words
ES_STOPWORDS: set = {
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
EN_STOPWORDS: set = {
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

def _clean_tokens(text: str) -> List[str]:
    """Tokenizes text into lowercase alpha words."""
    import re
    if not text:
        return []
    tokens = re.findall(r"\b[a-zA-ZáéíóúüñÁÉÍÓÚÜÑ']+\b", text.lower())
    return [t for t in tokens if len(t) > 0]

def _score_text_language(text: Optional[str]) -> Tuple[Optional[str], int, int]:
    """
    Scores text against ES and EN stopword lists.
    Returns (detected_lang, es_matches, en_matches).
    """
    if not text:
        return None, 0, 0
    words = _clean_tokens(text)
    if not words:
        return None, 0, 0

    es_matches = sum(1 for w in words if w in ES_STOPWORDS)
    en_matches = sum(1 for w in words if w in EN_STOPWORDS)

    has_spanish_diacritics = any(c in "áéíóúñÁÉÍÓÚÑ" for c in text)
    if has_spanish_diacritics:
        es_matches += 1

    if es_matches > en_matches:
        return "es", es_matches, en_matches
    elif en_matches > es_matches:
        return "en", es_matches, en_matches
    return None, es_matches, en_matches

def _extract_speaker_intro_name(text: Optional[str]) -> Optional[str]:
    """
    Extract a speaker's first name if they explicitly introduce themselves in speech.
    e.g. 'Hello, my name is Tobias' -> 'Tobias'
         'Hi everyone, I'm Adriana.' -> 'Adriana'
    """
    import re
    if not text:
        return None

    # Matches: "my name is <Name>", "I'm <Name>", "I am <Name>"
    m = re.search(r"\b(?:my name is|i'm|i am)\s+([A-Z][a-z]{2,15})\b", text)
    if m:
        name = m.group(1)
        # Avoid common false positives
        if name.lower() not in {"sorry", "sure", "here", "just", "back", "going", "ready", "happy", "glad", "not", "so", "fine", "good"}:
            return name
    return None

def notify_mac_diarization_complete(video_id: str, speaker_count: int, title: Optional[str] = None, duration_sec: Optional[float] = None):
    """Post native macOS Notification Center banner with PodcastThis icon and sound via NotifiCLI."""
    import subprocess
    import shutil
    import os

    time_str = f" in {_format_duration(duration_sec)}" if duration_sec is not None and duration_sec > 0 else ""
    display_title = title.strip() if title and title.strip() else ""
    if display_title:
        msg = f"Found {speaker_count} speakers for \"{display_title}\"{time_str}."
    else:
        msg = f"Found {speaker_count} speakers for episode{time_str}."

    icon_png = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../ios-app/Icon.png"))

    notificli_bin = shutil.which("notificli") or "/opt/homebrew/bin/notificli"
    if os.path.exists(notificli_bin):
        # 1. Try with custom PodcastThis icon variant
        try:
            res = subprocess.run([
                notificli_bin,
                "-icon", "PodcastThis",
                "--persistent",
                "--title", "Speaker Analysis Complete",
                "--message", msg,
                "--image", icon_png
            ], capture_output=True, text=True, timeout=3)
            if res.returncode == 0:
                logger.info(f"[{video_id}] Posted persistent macOS notification banner via NotifiCLI (-icon PodcastThis)")
                return
        except Exception:
            pass

        # 2. Fall back to standard NotifiCLI with PodcastThis image
        try:
            res2 = subprocess.run([
                notificli_bin,
                "--persistent",
                "--title", "Speaker Analysis Complete",
                "--message", msg,
                "--image", icon_png
            ], capture_output=True, text=True, timeout=3)
            if res2.returncode == 0:
                logger.info(f"[{video_id}] Posted persistent macOS notification banner via NotifiCLI (--image)")
                return
        except Exception:
            pass

    # 3. Fallback to osascript
    safe_msg = msg.replace('"', '\\"')
    script = f'display notification "{safe_msg}" with title "Speaker Analysis Complete"'
    try:
        subprocess.run(["osascript", "-e", script], check=False)
        logger.info(f"[{video_id}] Posted macOS notification banner via osascript")
    except Exception as e:
        logger.warning(f"[{video_id}] Could not post macOS notification: {e}")

def notify_device_diarization_complete(video_id: str, speaker_count: int, title: Optional[str] = None, duration_sec: Optional[float] = None):
    """Trigger native macOS notification and remote iPhone HUD toast via SSH."""
    import subprocess

    # 1. Native macOS Notification Center banner with sound
    notify_mac_diarization_complete(video_id, speaker_count, title=title, duration_sec=duration_sec)

    # 2. Remote iPhone alerts (RemoteCompanion HUD Toast + uiopen sync + uialert fallback)
    time_str = f" in {_format_duration(duration_sec)}" if duration_sec is not None and duration_sec > 0 else ""
    clean_title = (title or "Episode").replace("'", "").replace('"', '').strip()
    if len(clean_title) > 60:
        clean_title = clean_title[:57] + "..."

    # Clean formatted message matching exact notification style
    toast_body = f"Found {speaker_count} speakers for \"{clean_title}\"{time_str}."
    alert_title = "Speaker Analysis Complete"

    cmd = (
        f"/var/jb/usr/bin/rc toast 'Speaker Analysis Complete' '{toast_body}' 'waveform' 2>/dev/null; "
        f"/var/jb/usr/bin/uiopen 'podcastthis://diarization-done?video_id={video_id}' 2>/dev/null || "
        f"nohup /var/jb/usr/bin/uialert -b '{toast_body}' '{alert_title}' >/dev/null 2>&1 &"
    )
    for host in [os.environ.get("DEVICE_HOST", "iphone.local")]:
        device_pass = os.environ.get("DEVICE_PASS", "")
        if not device_pass:
            logger.warning(f"[{video_id}] DEVICE_PASS not set, skipping iPhone notification")
            break
        try:
            subprocess.Popen([
                "sshpass", "-p", device_pass,
                "ssh", "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=4",
                f"mobile@{host}",
                cmd
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            logger.info(f"[{video_id}] Triggered completion notification to {host}")
        except Exception as e:
            logger.warning(f"[{video_id}] Could not notify {host}: {e}")

def run_diarization_job(video_id: str, temp_audio_path: str, temp_dir: str, title: Optional[str] = None, detect_language: bool = False):
    """Worker function to process audio file and update ACTIVE_JOBS state."""
    try:
        import whisperx
        from datetime import datetime, timezone

        # Send non-persistent notification that speaker analysis has started
        notify_mac_diarization_start(video_id, title=title)

        load_models()

        if video_id in ACTIVE_JOBS:
            ACTIVE_JOBS[video_id]["status"] = "processing"
            ACTIVE_JOBS[video_id]["step"] = "Transcribing audio..."
            if title and not ACTIVE_JOBS[video_id].get("title"):
                ACTIVE_JOBS[video_id]["title"] = title
            if "start_time" not in ACTIVE_JOBS[video_id]:
                ACTIVE_JOBS[video_id]["start_time"] = time.time()
        else:
            ACTIVE_JOBS[video_id] = {
                "status": "processing",
                "step": "Transcribing audio...",
                "title": title or f"Episode {video_id[:8]}",
                "start_time": time.time(),
            }
        notify_menubar_updated()

        logger.info(f"[{video_id}] Loading audio: {temp_audio_path}")
        audio = whisperx.load_audio(temp_audio_path)

        # 1. Transcribe audio
        update_job_step(video_id, "Transcribing audio...")
        logger.info(f"[{video_id}] Transcribing audio with WhisperX (condition_on_previous_text=False)...")
        if WHISPER_MODEL is not None and hasattr(WHISPER_MODEL, "options"):
            from dataclasses import replace
            try:
                WHISPER_MODEL.options = replace(
                    WHISPER_MODEL.options,
                    condition_on_previous_text=False,
                    repetition_penalty=1.2,
                    no_repeat_ngram_size=3,
                    temperatures=[0.0, 0.2, 0.4]
                )
            except Exception as opt_err:
                logger.debug(f"[{video_id}] Could not update WHISPER_MODEL.options: {opt_err}")
        result = WHISPER_MODEL.transcribe(audio, batch_size=16)

        # 2. Align timestamps
        update_job_step(video_id, "Aligning transcript timestamps...")
        logger.info(f"[{video_id}] Aligning transcript...")
        align_model, metadata = whisperx.load_align_model(
            language_code=result.get("language", "en"),
            device="cpu"
        )
        aligned_result = whisperx.align(
            result["segments"],
            align_model,
            metadata,
            audio,
            device="cpu",
            return_char_alignments=False
        )

        # 3. Perform Speaker Diarization
        update_job_step(video_id, "Diarizing speakers with PyAnnote...")
        logger.info(f"[{video_id}] Running speaker diarization...")
        diarize_segments = DIARIZATION_PIPELINE(audio)

        # 4. Assign speaker labels
        update_job_step(video_id, "Assigning speaker labels...")
        logger.info(f"[{video_id}] Assigning speaker labels...")
        diarized_result = whisperx.assign_word_speakers(diarize_segments, aligned_result)

        # 5. Extract fine-grained word-level segments
        raw_segments = []
        for seg in diarized_result.get("segments", []):
            seg_speaker = seg.get("speaker") or "UNKNOWN"
            words = seg.get("words", [])
            seg_raw_text = seg.get("text", "").strip()

            words_added = 0
            if words:
                for w in words:
                    w_text = w.get("word", "").strip()
                    if not w_text:
                        continue
                    w_start = w.get("start")
                    w_end = w.get("end")
                    if w_start is None:
                        w_start = seg.get("start", 0.0)
                    if w_end is None:
                        w_end = seg.get("end", w_start + 0.1)

                    w_start = round(float(w_start), 2)
                    w_end = round(float(w_end), 2)
                    w_spk = w.get("speaker") or seg_speaker

                    if w_end > w_start:
                        raw_segments.append({
                            "speaker": w_spk,
                            "start": w_start,
                            "end": w_end,
                            "text": w_text
                        })
                        words_added += 1

            if not words or words_added == 0:
                start = round(float(seg.get("start", 0.0)), 2)
                end = round(float(seg.get("end", 0.0)), 2)
                if end > start:
                    raw_segments.append({
                        "speaker": seg_speaker,
                        "start": start,
                        "end": end,
                        "text": seg_raw_text
                    })

        # Backfill any acoustic speech turns detected by PyAnnote that had no transcribed words (e.g. foreign speech dropped by whisper)
        if diarize_segments is not None and hasattr(diarize_segments, "iterrows"):
            for _, row in diarize_segments.iterrows():
                p_start = float(row.get("start", 0.0))
                p_end = float(row.get("end", 0.0))
                p_spk = row.get("speaker") or "UNKNOWN"
                if p_end - p_start < 1.0 or p_spk == "UNKNOWN":
                    continue

                covered = False
                for r in raw_segments:
                    overlap = min(p_end, r["end"]) - max(p_start, r["start"])
                    if overlap >= 0.5:
                        covered = True
                        break
                if not covered:
                    raw_segments.append({
                        "speaker": p_spk,
                        "start": round(p_start, 2),
                        "end": round(p_end, 2),
                        "text": ""
                    })

        raw_segments.sort(key=lambda x: x["start"])

        # 5a. Absorb short UNKNOWN fillers/noises (< 2.0s) and attribute to adjacent speaker turns
        for i in range(len(raw_segments)):
            if raw_segments[i]["speaker"] == "UNKNOWN":
                dur = raw_segments[i]["end"] - raw_segments[i]["start"]
                if dur <= 2.0:
                    prev_spk = raw_segments[i - 1]["speaker"] if i > 0 else None
                    next_spk = raw_segments[i + 1]["speaker"] if i + 1 < len(raw_segments) else None

                    # If sandwiched between the same speaker
                    if prev_spk and prev_spk != "UNKNOWN" and prev_spk == next_spk:
                        raw_segments[i]["speaker"] = prev_spk
                    # If adjacent to only one known speaker
                    elif prev_spk and prev_spk != "UNKNOWN" and (not next_spk or next_spk == "UNKNOWN"):
                        raw_segments[i]["speaker"] = prev_spk
                    elif next_spk and next_spk != "UNKNOWN" and (not prev_spk or prev_spk == "UNKNOWN"):
                        raw_segments[i]["speaker"] = next_spk
                    elif prev_spk and next_spk and prev_spk != "UNKNOWN" and next_spk != "UNKNOWN":
                        # Attribute to closest speaker turn if adjacent
                        prev_gap = raw_segments[i]["start"] - raw_segments[i - 1]["end"]
                        next_gap = raw_segments[i + 1]["start"] - raw_segments[i]["end"]
                        if prev_gap <= next_gap and prev_gap <= 0.5:
                            raw_segments[i]["speaker"] = prev_spk
                        elif next_gap < prev_gap and next_gap <= 0.5:
                            raw_segments[i]["speaker"] = next_spk

        # Filter out remaining floating UNKNOWN noise tokens (< 2.0s) that have no known speaker
        filtered_segments = []
        for s in raw_segments:
            if s["speaker"] == "UNKNOWN" and (s["end"] - s["start"]) < 2.0:
                continue
            filtered_segments.append(s)

        # 5b. Consolidate consecutive words/segments of the same speaker (bridging natural pauses up to 1.5s)
        merged_raw_segments = []
        speaker_durations = {}
        speaker_turn_candidates: Dict[str, List[str]] = {}
        speaker_first_timestamps = {}

        for seg_dict in filtered_segments:
            spk = seg_dict["speaker"]
            s_start = seg_dict["start"]
            s_end = seg_dict["end"]
            text = seg_dict.get("text", "")

            if not merged_raw_segments:
                merged_raw_segments.append({"speaker": spk, "start": s_start, "end": s_end, "text": text})
            else:
                prev = merged_raw_segments[-1]
                # Merge if same speaker and gap is <= 1.5s (encompassing breath, mouth clicks, ambient pause)
                if prev["speaker"] == spk and (s_start - prev["end"]) <= 1.5:
                    prev["end"] = max(prev["end"], s_end)
                    if text:
                        prev["text"] = f"{prev.get('text', '')} {text}".strip()
                else:
                    merged_raw_segments.append({"speaker": spk, "start": s_start, "end": s_end, "text": text})

            # Collect speech turn candidates for each speaker (up to 8 candidate turns for selection)
            if spk != "UNKNOWN" and text and len(text.strip()) >= 3:
                if spk not in speaker_turn_candidates:
                    speaker_turn_candidates[spk] = []
                if len(speaker_turn_candidates[spk]) < 8:
                    speaker_turn_candidates[spk].append(text.strip())

        # 5c. Detect language for each merged segment using audio sampling with primary language fallback
        primary_lang = (result.get("language") or "en").lower()
        merged_segments: List[SpeakerSegment] = []
        audio_sr = 16000
        total_audio_len = len(audio)
        lang_duration_map = {}

        LANG_NAME_MAP = {
            "es": "Spanish",
            "fr": "French",
            "de": "German",
            "it": "Italian",
            "pt": "Portuguese",
            "ru": "Russian",
            "zh": "Chinese",
            "ja": "Japanese",
            "ko": "Korean",
            "ar": "Arabic",
            "hi": "Hindi",
            "nl": "Dutch",
            "pl": "Polish",
            "tr": "Turkish",
        }

        # Build repository of earlier English phrases to detect decoder repetition hallucinations
        prior_english_phrases: List[str] = [
            (s.get("text") or "").strip().lower()
            for s in merged_raw_segments
            if s.get("text") and len(s.get("text").strip()) >= 8
        ]

        if not detect_language:
            logger.info(f"[{video_id}] Language detection disabled by user request. Bypassing segment-by-segment language scan.")
            for seg in merged_raw_segments:
                s_start = seg["start"]
                s_end = seg["end"]
                dur = max(0.0, s_end - s_start)
                merged_segments.append(SpeakerSegment(
                    speaker_id=seg["speaker"],
                    start=s_start,
                    end=s_end,
                    language=primary_lang,
                    text=seg.get("text")
                ))
                lang_duration_map[primary_lang] = lang_duration_map.get(primary_lang, 0.0) + dur
            detected_languages_list = [primary_lang]
            speaker_dominant_non_english: Dict[str, str] = {}
        else:
            update_job_step(video_id, "Detecting spoken languages across segments...")
            logger.info(f"[{video_id}] Detecting languages for {len(merged_raw_segments)} speech segments (primary: {primary_lang})...")

            raw_classified_segments = []
            speaker_lang_stats: Dict[str, Dict[str, float]] = {}

            for seg in merged_raw_segments:
                s_start = seg["start"]
                s_end = seg["end"]
                spk = seg["speaker"]
                dur = max(0.0, s_end - s_start)
                seg_lang = primary_lang
                seg_text = (seg.get("text") or "").strip()

                text_lang, es_cnt, en_cnt = _score_text_language(seg_text)

                # Acoustic detection
                det_lang = None
                det_prob = 0.0
                if dur >= 1.2 and WHISPER_MODEL is not None and hasattr(WHISPER_MODEL, "model") and hasattr(WHISPER_MODEL.model, "detect_language"):
                    try:
                        start_sample = max(0, int(s_start * audio_sr))
                        end_sample = min(total_audio_len, int(s_end * audio_sr))
                        if end_sample - start_sample >= int(1.2 * audio_sr):
                            chunk = audio[start_sample:end_sample]
                            det_lang_raw, det_prob_raw, _ = WHISPER_MODEL.model.detect_language(chunk)
                            if det_lang_raw:
                                det_lang = det_lang_raw.lower()
                                det_prob = det_prob_raw
                    except Exception as detect_err:
                        logger.debug(f"[{video_id}] Language detection error on segment [{s_start}-{s_end}]: {detect_err}")

                # Suppress known Whisper low-confidence acoustic hallucinations
                if det_lang in ["cy", "gd", "la", "gl", "el"] and det_prob < 0.85:
                    det_lang = None

                # Classification decision combining text stopwords and acoustic detection
                if text_lang == "es" and es_cnt >= 1:
                    # Explicit Spanish vocabulary in transcribed text takes priority
                    seg_lang = "es"
                elif det_lang == "es" and det_prob >= 0.55:
                    seg_lang = "es"
                elif text_lang == "en" and en_cnt >= 2 and (not det_lang or det_lang == "en"):
                    seg_lang = "en"
                elif det_lang and det_lang != "en" and det_prob >= 0.65:
                    seg_lang = det_lang
                else:
                    seg_lang = primary_lang

                final_text = seg_text if seg_text else None
                raw_classified_segments.append({
                    "speaker": spk,
                    "start": s_start,
                    "end": s_end,
                    "language": seg_lang,
                    "text": final_text,
                    "dur": dur
                })

                if spk != "UNKNOWN":
                    if spk not in speaker_lang_stats:
                        speaker_lang_stats[spk] = {"total_dur": 0.0, "es_dur": 0.0, "en_dur": 0.0, "es_turns": 0, "en_turns": 0, "total_turns": 0}
                    speaker_lang_stats[spk]["total_dur"] += dur
                    speaker_lang_stats[spk]["total_turns"] += 1
                    if seg_lang == "es":
                        speaker_lang_stats[spk]["es_dur"] += dur
                        speaker_lang_stats[spk]["es_turns"] += 1
                    elif seg_lang == "en":
                        speaker_lang_stats[spk]["en_dur"] += dur
                        speaker_lang_stats[spk]["en_turns"] += 1

            # Determine speaker-level dominant languages
            speaker_dominant_map: Dict[str, str] = {}
            for spk, stats in speaker_lang_stats.items():
                t_dur = stats["total_dur"]
                if t_dur > 0:
                    es_ratio = stats["es_dur"] / t_dur
                    if es_ratio >= 0.65 or (stats["es_turns"] >= 10 and stats["es_turns"] / stats["total_turns"] >= 0.60):
                        speaker_dominant_map[spk] = "es"
                    elif (stats["en_dur"] / t_dur) >= 0.70:
                        speaker_dominant_map[spk] = "en"

            # Pass 2: Speaker context inheritance for short/untranscribed segments
            for item in raw_classified_segments:
                spk = item["speaker"]
                assigned_lang = item["language"]
                seg_text = item["text"] or ""
                dur = item["dur"]

                if speaker_dominant_map.get(spk) == "es":
                    text_lang, es_cnt, en_cnt = _score_text_language(seg_text)
                    # Inherit Spanish unless the turn is clearly English with multiple English stopwords
                    if text_lang != "en" or en_cnt == 0:
                        assigned_lang = "es"
                    elif en_cnt <= 1 and es_cnt >= 1:
                        assigned_lang = "es"
                    elif not seg_text:
                        assigned_lang = "es"

                merged_segments.append(SpeakerSegment(
                    speaker_id=spk,
                    start=item["start"],
                    end=item["end"],
                    language=assigned_lang,
                    text=item["text"]
                ))
                lang_duration_map[assigned_lang] = lang_duration_map.get(assigned_lang, 0.0) + dur

            # Compute detected_languages summary list sorted by prevalence
            detected_languages_list = []
            if lang_duration_map:
                total_dur = sum(lang_duration_map.values())
                for lang, dur in sorted(lang_duration_map.items(), key=lambda x: x[1], reverse=True):
                    # Include languages representing >= 2.0% of speech or at least 8 seconds, suppressing spurious noise
                    if total_dur > 0 and ((dur / total_dur) >= 0.02 or dur >= 8.0):
                        if lang not in ["cy", "gd", "la", "gl", "el"] or (dur / total_dur) >= 0.10:
                            detected_languages_list.append(lang)
                if not detected_languages_list:
                    detected_languages_list = [primary_lang]
            else:
                detected_languages_list = [primary_lang]

        # Calculate final speaker durations and first timestamps from consolidated segments
        for seg in merged_segments:
            spk = seg.speaker_id
            if spk == "UNKNOWN":
                continue
            dur = max(0.0, seg.end - seg.start)
            speaker_durations[spk] = speaker_durations.get(spk, 0.0) + dur
            if spk not in speaker_first_timestamps:
                speaker_first_timestamps[spk] = seg.start

        speakers: List[SpeakerProfile] = []
        sorted_speakers = sorted(speaker_durations.items(), key=lambda x: x[1], reverse=True)

        for idx, (spk_id, dur) in enumerate(sorted_speakers, 1):
            candidates = speaker_turn_candidates.get(spk_id, [])
            sample = _score_and_extract_speaker_sample(candidates)
            
            # Check if speaker explicitly stated their own name in their turns
            inferred_name = None
            for c in candidates:
                inferred_name = _extract_speaker_intro_name(c)
                if inferred_name:
                    break

            if inferred_name:
                name = f"{inferred_name} (Speaker {idx})" if spk_id.startswith("SPEAKER_") else f"{inferred_name} ({spk_id})"
            else:
                name = f"Speaker {idx}" if spk_id.startswith("SPEAKER_") else spk_id

            dom_lang = speaker_dominant_map.get(spk_id) if "speaker_dominant_map" in locals() else None
            is_non_en = (dom_lang is not None and dom_lang != "en")

            speakers.append(SpeakerProfile(
                id=spk_id,
                default_name=name,
                is_skipped=False,
                total_duration=round(dur, 2),
                sample_text=sample,
                first_timestamp=speaker_first_timestamps.get(spk_id),
                is_non_english=is_non_en,
                dominant_language=dom_lang
            ))

        now_iso = datetime.now(timezone.utc).isoformat()
        response = DiarizationResponse(
            video_id=video_id,
            speakers=speakers,
            segments=merged_segments,
            analyzed_date=now_iso,
            detected_languages=detected_languages_list,
            filter_english_only=False
        )

        save_cached_result(video_id, response)
        if video_id in ACTIVE_JOBS:
            ACTIVE_JOBS[video_id]["status"] = "completed"
            ACTIVE_JOBS[video_id]["step"] = "Completed"
            ACTIVE_JOBS[video_id]["result"] = response.model_dump()
        else:
            ACTIVE_JOBS[video_id] = {
                "status": "completed",
                "step": "Completed",
                "result": response.model_dump(),
            }
        notify_menubar_updated()
        logger.info(f"[{video_id}] Diarization complete! Found {len(speakers)} speakers and {len(merged_segments)} segments.")

        elapsed_sec = None
        if video_id in ACTIVE_JOBS and "start_time" in ACTIVE_JOBS[video_id]:
            elapsed_sec = time.time() - ACTIVE_JOBS[video_id]["start_time"]

        # Remotely trigger completion notification on the iPhone via SSH
        notify_device_diarization_complete(video_id, len(speakers), title=title, duration_sec=elapsed_sec)

    except Exception as e:
        logger.error(f"[{video_id}] Diarization error: {e}", exc_info=True)
        if video_id in ACTIVE_JOBS:
            ACTIVE_JOBS[video_id]["status"] = "failed"
            ACTIVE_JOBS[video_id]["step"] = "Failed"
            ACTIVE_JOBS[video_id]["error"] = str(e)
        else:
            ACTIVE_JOBS[video_id] = {
                "status": "failed",
                "step": "Failed",
                "error": str(e),
            }
        notify_menubar_updated()
    finally:
        global LAST_ACTIVITY_TIME
        LAST_ACTIVITY_TIME = time.time()
        shutil.rmtree(temp_dir, ignore_errors=True)

@app.get("/health")
def health_check():
    idle_secs = int(time.time() - LAST_ACTIVITY_TIME)
    return {
        "status": "online",
        "service": "PodcastThis WhisperX Diarization Service",
        "device": DEVICE,
        "hf_token_configured": bool(HF_TOKEN),
        "active_jobs_count": len([j for j in ACTIVE_JOBS.values() if j.get("status") == "processing"]),
        "idle_timeout_minutes": IDLE_TIMEOUT_MINUTES,
        "idle_seconds": idle_secs,
        "seconds_until_autoshutdown": max(0, (IDLE_TIMEOUT_MINUTES * 60) - idle_secs) if IDLE_TIMEOUT_MINUTES > 0 else None
    }

@app.post("/shutdown")
def shutdown_service(background_tasks: BackgroundTasks):
    """Cleanly shutdown the service process."""
    def kill_process():
        import time, signal
        time.sleep(0.5)
        os.kill(os.getpid(), signal.SIGTERM)
    
    background_tasks.add_task(kill_process)
    return {"status": "shutting_down", "message": "WhisperX service is shutting down."}

@app.delete("/diarize/{video_id}/cache")
@app.post("/diarize/{video_id}/clear")
def clear_job_cache(video_id: str):
    """Clear cached result and active job for a video_id."""
    cache_file = os.path.join(CACHE_DIR, f"{video_id}.json")
    removed = False
    if os.path.exists(cache_file):
        try:
            os.remove(cache_file)
            removed = True
            logger.info(f"[{video_id}] Cleared cache on disk.")
        except Exception as e:
            logger.warning(f"[{video_id}] Failed to delete cache file: {e}")
    if video_id in ACTIVE_JOBS:
        del ACTIVE_JOBS[video_id]
        removed = True
        notify_menubar_updated()
    return {"status": "cleared" if removed else "not_found", "video_id": video_id}

@app.get("/diarize/{video_id}/status")
def get_job_status(video_id: str):
    """Poll job status or fetch cached result."""
    # 1. Check disk cache
    cached = get_cached_result(video_id)
    if cached:
        return {
            "status": "completed",
            "result": cached.model_dump()
        }

    # 2. Check active in-memory job
    if video_id in ACTIVE_JOBS:
        return ACTIVE_JOBS[video_id]

    return {"status": "not_found"}

@app.post("/diarize")
async def diarize_audio(
    background_tasks: BackgroundTasks,
    file: Optional[UploadFile] = File(None),
    video_id: Optional[str] = Form(None),
    title: Optional[str] = Form(None),
    force: Optional[str] = Form(None),
    detect_language: Optional[str] = Form("false"),
):
    """
    Perform speaker diarization on uploaded audio file.
    Returns cached result immediately if available, or queues background processing.
    """
    vid = video_id or (os.path.splitext(file.filename)[0] if file and file.filename else str(uuid.uuid4()))
    is_force = str(force).lower() in ("true", "1", "yes") if force else False
    is_detect_lang = str(detect_language).lower() in ("true", "1", "yes") if detect_language else False

    if is_force:
        # Clear existing disk cache for this video_id
        cache_file = os.path.join(CACHE_DIR, f"{vid}.json")
        if os.path.exists(cache_file):
            try:
                os.remove(cache_file)
                logger.info(f"[{vid}] Removed existing cache due to force re-analysis request.")
            except Exception as e:
                logger.warning(f"[{vid}] Could not remove cache file {cache_file}: {e}")
        if vid in ACTIVE_JOBS:
            del ACTIVE_JOBS[vid]
            notify_menubar_updated()
    else:
        # Return cached result if already completed
        cached = get_cached_result(vid)
        if cached:
            return cached

    if file is None:
        raise HTTPException(status_code=400, detail="Audio file must be provided.")

    # Save uploaded file to temp path
    temp_dir = tempfile.mkdtemp()
    temp_audio_path = os.path.join(temp_dir, f"{uuid.uuid4()}_{file.filename or 'audio.m4a'}")
    
    try:
        with open(temp_audio_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
    except Exception as e:
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise HTTPException(status_code=500, detail=f"Failed to save uploaded audio: {str(e)}")

    # Mark active job
    job_title = title or (file.filename if file and file.filename else f"Episode {vid[:8]}")
    ACTIVE_JOBS[vid] = {
        "status": "processing",
        "step": "Audio uploaded. Initializing WhisperX on computer...",
        "title": job_title,
        "start_time": time.time(),
    }
    notify_menubar_updated()

    # Run in background executor so it doesn't block FastAPI
    EXECUTOR.submit(run_diarization_job, vid, temp_audio_path, temp_dir, title, is_detect_lang)

    # Immediately respond with 200/accepted so the client upload completes in 2-3 seconds
    return {
        "status": "processing",
        "video_id": vid,
        "step": "Audio received. Processing on computer...",
        "message": "Job is running in background. Poll /diarize/{video_id}/status for progress."
    }

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    host = os.environ.get("HOST", "0.0.0.0")
    print(f"[*] Starting PodcastThis WhisperX Diarization Service on http://{host}:{port}")

    if HAS_PYOBJC and sys.platform == "darwin":
        import threading

        STATUS_BAR_MANAGER = StatusBarManager()
        STATUS_BAR_MANAGER.setup()

        AppHelper.installMachInterrupt()
        MachSignals.signal(signal.SIGTERM, AppHelper.machInterrupt)

        config = uvicorn.Config(
            app,
            host=host,
            port=port,
            log_level="info",
            loop="asyncio"
        )
        server = uvicorn.Server(config)
        uvicorn_thread = threading.Thread(target=server.run, daemon=True)
        uvicorn_thread.start()

        try:
            AppHelper.runEventLoop()
        except KeyboardInterrupt:
            pass
        finally:
            logger.info("[*] Shutting down WhisperX service...")
            server.should_exit = True
    else:
        uvicorn.run("server:app", host=host, port=port, reload=False)

