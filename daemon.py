import sys
import subprocess
import collections
import re
import time
import json
import os
import logging
import hashlib
from typing import Optional, Dict, List
from openai import OpenAI

# Structured Logging
logger = logging.getLogger("invisible-cto")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logging.Formatter('{"timestamp": "%(asctime)s", "level": "%(levelname)s", "message": %(message)s}'))
logger.addHandler(handler)

# Constants
LOG_BUFFER_SIZE = 30
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_SECONDS", 60))
LOCK_FILE = "/tmp/invisible_cto.lock"
CACHE_FILE = "/tmp/invisible_cto_cache.json"
DEFAULT_DEPLOY_CMD = os.environ.get("DEPLOY_CMD", "railway up").split()
DEFAULT_LOG_CMD = os.environ.get("LOG_CMD", "railway logs --tail").split()

# Regex for common Python and general errors/exceptions
ERROR_REGEX = re.compile(
    r"(?i)(Exception|Error|Traceback|FATAL|PANIC|ReferenceError|TypeError|SyntaxError|ValueError|KeyError|IndexError|AttributeError|ModuleNotFoundError)"
)

SYSTEM_PROMPT = """You are an elite, autonomous AI software engineer (The Invisible CTO).
An error was detected in the application logs.
Your task is to analyze the log buffer and provide a strict JSON patch to fix the code.

You MUST return ONLY a valid JSON object with the following exact structure, no markdown formatting or extra text:
{
    "file_path": "path/to/file.py",
    "old_code": "exact string of code to replace (must match exactly)",
    "new_code": "new string of code to replace it with"
}

If you cannot determine the file or fix, return an empty JSON object: {}
"""

class StateManager:
    @staticmethod
    def acquire_lock():
        if os.path.exists(LOCK_FILE):
            return False
        with open(LOCK_FILE, "w") as f:
            f.write(str(os.getpid()))
        return True

    @staticmethod
    def release_lock():
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)

    @staticmethod
    def get_cache():
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, "r") as f:
                return json.load(f)
        return {}

    @staticmethod
    def save_cache(cache):
        with open(CACHE_FILE, "w") as f:
            json.dump(cache, f)

class Worker:
    def __init__(self, client: OpenAI):
        self.client = client
        self.history = collections.deque(maxlen=5) # Loop detection

    def analyze_and_patch(self, log_context: str) -> Optional[dict]:
        # Loop detection: hash the context
        context_hash = hashlib.sha256(log_context.encode()).hexdigest()
        if context_hash in self.history:
            logger.warning(json.dumps({"event": "loop_detected", "hash": context_hash}))
            return None
        self.history.append(context_hash)

        # Semantic caching check
        cache = StateManager.get_cache()
        if context_hash in cache:
            logger.info(json.dumps({"event": "cache_hit", "hash": context_hash}))
            return cache[context_hash]

        logger.info(json.dumps({"event": "llm_call_initiated"}))
        try:
            response = self.client.chat.completions.create(
                model=os.environ.get("OPENAI_MODEL", "gpt-4o"),
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": f"Here is the recent log output containing the error:\n\n{log_context}\n\nPlease provide the JSON patch."}
                ],
                temperature=0.2
            )
            content = response.choices[0].message.content.strip()
            # Clean Markdown
            content = re.sub(r"^```json\s*", "", content)
            content = re.sub(r"\s*```$", "", content)
            
            patch = json.loads(content)
            
            # Cache the result
            cache[context_hash] = patch
            StateManager.save_cache(cache)
            
            return patch if patch else None
        except Exception as e:
            logger.error(json.dumps({"event": "error", "message": str(e)}))
            return None

class Orchestrator:
    def __init__(self):
        self.client = self._get_openai_client()
        self.worker = Worker(self.client)
        self.log_buffer = collections.deque(maxlen=LOG_BUFFER_SIZE)
        self.last_fix_time = 0

    def _get_openai_client(self) -> OpenAI:
        api_key = os.environ.get("OPENAI_API_KEY")
        base_url = os.environ.get("OPENAI_BASE_URL")
        return OpenAI(api_key=api_key, base_url=base_url)

    def run(self):
        logger.info(json.dumps({"event": "daemon_started"}))
        try:
            process = subprocess.Popen(
                DEFAULT_LOG_CMD,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1
            )
        except Exception as e:
            logger.error(json.dumps({"event": "critical_failure", "message": f"Could not start log process: {e}"}))
            sys.exit(1)

        try:
            for line in iter(process.stdout.readline, ""):
                line = line.rstrip('\n')
                self.log_buffer.append(line)
                
                if ERROR_REGEX.search(line):
                    self._handle_error(line)
        except KeyboardInterrupt:
            logger.info(json.dumps({"event": "daemon_stopped"}))
        finally:
            if process.poll() is None:
                process.terminate()

    def _handle_error(self, line):
        if time.time() - self.last_fix_time < COOLDOWN_SECONDS:
            return

        if not StateManager.acquire_lock():
            return

        try:
            logger.warning(json.dumps({"event": "error_detected", "log": line}))
            patch = self.worker.analyze_and_patch("\n".join(self.log_buffer))
            
            if patch and self._apply_patch(patch):
                self._deploy()
                self.last_fix_time = time.time()
                self.log_buffer.clear()
        finally:
            StateManager.release_lock()

    def _apply_patch(self, patch: dict) -> bool:
        try:
            file_path = patch.get("file_path")
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()
            if patch["old_code"] not in content:
                return False
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(content.replace(patch["old_code"], patch["new_code"], 1))
            logger.info(json.dumps({"event": "patch_applied", "file": file_path}))
            return True
        except Exception as e:
            logger.error(json.dumps({"event": "patch_failed", "error": str(e)}))
            return False

    def _deploy(self):
        logger.info(json.dumps({"event": "deploy_initiated"}))
        subprocess.run(DEFAULT_DEPLOY_CMD, capture_output=True)
        logger.info(json.dumps({"event": "deploy_completed"}))

if __name__ == "__main__":
    Orchestrator().run()
