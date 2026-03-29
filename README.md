# 🕵️‍♂️ Invisible CTO

**An AI DevOps Agent for Vibe Coders.**

Invisible CTO is a silent, self-healing background daemon for your apps. It tails your live production logs, detects crashes, writes code patches, and triggers auto-redeploys—all without human intervention. Like having a tireless CTO on call 24/7.

## 🚀 The Self-Healing Loop
1. **Monitor:** Tails your server logs (Railway default).
2. **Detect:** Catches exceptions, syntax errors, and fatal crashes in real-time.
3. **Analyze:** Ships the 30-line crash context to an LLM.
4. **Patch:** Generates a surgical JSON patch and fixes your local code.
5. **Deploy:** Automatically triggers a redeploy.

## 🛠️ Installation & Usage (No PyPI needed)

You don't need to install this via `pip`. Just download the script into your project and run it.

```bash
# 1. Download the core daemon into your project directory
curl -O https://raw.githubusercontent.com/Dev-31/invisible-cto/main/daemon.py

# 2. Set your OpenAI API Key
export OPENAI_API_KEY="sk-your-key"

# 3. Run the silent CTO in the background
python daemon.py
```

### Customization (Environment Variables)
The daemon is highly flexible. You can override the default log and deploy commands to fit your stack:

```bash
export LOG_CMD="railway logs --tail"
export DEPLOY_CMD="railway up"
export COOLDOWN_SECONDS="60"
export OPENAI_MODEL="gpt-4o-mini" # or any compatible model
```

## 🧠 Why?
Because you want to ship features, not fight servers. When a syntax error crashes production at 2 AM, Invisible CTO patches the file and deploys the fix in under 60 seconds while you sleep.

## ⚠️ Disclaimer
This agent writes code directly to your filesystem and triggers deployments automatically. Use in environments where you have version control (Git) enabled so you can revert AI patches if necessary.

---
*Built for the vibe coders. Ship faster.*