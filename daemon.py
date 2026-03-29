import sys
import subprocess
import collections
import re
import time
import json
import os
import logging
from typing import Optional
from openai import OpenAI

# Configure basic logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("invisible-cto")

# Constants
LOG_BUFFER_SIZE = 30
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_SECONDS", 60))
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

def get_openai_client() -> OpenAI:
    """Initialize the OpenAI client using environment variables."""
    api_key = os.environ.get("OPENAI_API_KEY")
    base_url = os.environ.get("OPENAI_BASE_URL")
    if not api_key:
        logger.warning("OPENAI_API_KEY is not set. Assuming default/configured auth or mocked proxy.")
    
    return OpenAI(api_key=api_key, base_url=base_url)

def call_llm_for_fix(client: OpenAI, log_buffer: str) -> Optional[dict]:
    """Call the LLM to get a JSON patch based on the log buffer."""
    logger.info("Calling LLM to analyze the error and generate a fix...")
    prompt = f"Here is the recent log output containing the error:\n\n{log_buffer}\n\nPlease provide the JSON patch."
    
    try:
        response = client.chat.completions.create(
            model=os.environ.get("OPENAI_MODEL", "gpt-4o"),
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": prompt}
            ],
            temperature=0.2
        )
        
        content = response.choices[0].message.content.strip()
        
        # Strip potential markdown block syntax if the LLM ignores instructions
        if content.startswith("```json"):
            content = content[7:]
        if content.startswith("```"):
            content = content[3:]
        if content.endswith("```"):
            content = content[:-3]
        
        content = content.strip()
        
        if not content or content == "{}":
            logger.info("LLM returned an empty patch. No fix applied.")
            return None
            
        patch = json.loads(content)
        
        if all(k in patch for k in ("file_path", "old_code", "new_code")):
            return patch
        else:
            logger.error(f"LLM returned invalid patch structure: {patch}")
            return None
            
    except Exception as e:
        logger.error(f"Error calling LLM: {e}")
        return None

def apply_patch(patch: dict) -> bool:
    """Apply the JSON patch to the local file system."""
    file_path = patch.get("file_path")
    old_code = patch.get("old_code")
    new_code = patch.get("new_code")
    
    # Simple sanitization
    if file_path.startswith("/") or ".." in file_path:
        logger.error(f"Unsafe file path provided by LLM: {file_path}")
        return False
        
    if not os.path.exists(file_path):
        logger.error(f"File not found: {file_path}")
        return False
        
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
            
        if old_code not in content:
            logger.error("old_code exact match not found in the file. Patch aborted.")
            return False
            
        new_content = content.replace(old_code, new_code, 1)
        
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(new_content)
            
        logger.info(f"Successfully patched {file_path}")
        return True
    except Exception as e:
        logger.error(f"Failed to apply patch: {e}")
        return False

def deploy_fix():
    """Deploy the application after fixing."""
    logger.info(f"Deploying fix using command: {' '.join(DEFAULT_DEPLOY_CMD)}")
    try:
        # Run deploy synchronously
        result = subprocess.run(DEFAULT_DEPLOY_CMD, capture_output=True, text=True, check=True)
        logger.info("Deployment successful.")
        logger.debug(result.stdout)
    except subprocess.CalledProcessError as e:
        logger.error(f"Deployment failed with exit code {e.returncode}")
        logger.error(f"Deploy error output: {e.stderr}")
    except FileNotFoundError:
        logger.error(f"Deploy command not found: {DEFAULT_DEPLOY_CMD[0]}")

def run_daemon():
    """Main daemon loop to tail logs and auto-heal."""
    logger.info("Starting Invisible CTO daemon...")
    client = get_openai_client()
    log_buffer = collections.deque(maxlen=LOG_BUFFER_SIZE)
    last_fix_time = 0
    
    logger.info(f"Tailing logs via command: {' '.join(DEFAULT_LOG_CMD)}")
    
    try:
        process = subprocess.Popen(
            DEFAULT_LOG_CMD,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
    except FileNotFoundError:
        logger.error(f"Log command not found: {DEFAULT_LOG_CMD[0]}. Ensure railway CLI is installed.")
        sys.exit(1)

    try:
        for line in iter(process.stdout.readline, ""):
            if not line:
                continue
                
            line = line.rstrip('\n')
            log_buffer.append(line)
            # Only print debug trace of logs if needed
            # logger.debug(f"LOG: {line}")
            
            if ERROR_REGEX.search(line):
                current_time = time.time()
                
                # Check cooldown
                if current_time - last_fix_time < COOLDOWN_SECONDS:
                    logger.warning("Error matched, but currently in cooldown period. Ignoring.")
                    continue
                    
                logger.warning(f"Error detected in logs: {line}")
                logger.info("Triggering Auto-Heal sequence...")
                
                # Capture the buffer context
                context = "\n".join(log_buffer)
                
                # Call LLM
                patch = call_llm_for_fix(client, context)
                if patch:
                    success = apply_patch(patch)
                    if success:
                        deploy_fix()
                        # Reset cooldown after successful fix cycle
                        last_fix_time = time.time()
                        # Clear buffer to avoid re-triggering immediately
                        log_buffer.clear()
                    else:
                        logger.error("Auto-Heal patch failed to apply.")
                else:
                    logger.error("Auto-Heal failed to generate a patch.")
                
    except KeyboardInterrupt:
        logger.info("Daemon interrupted by user. Shutting down...")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()

if __name__ == "__main__":
    run_daemon()
