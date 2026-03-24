# Invisible CTO

**AI DevOps agent for vibe coders** — ships products, not excuses.

The core loop: **Crash detected → AI analyzes → patch written → auto-deployed → verified → repeats silently.**

Zero human intervention after setup. Like a silent, tireless CTO on call 24/7.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                 Invisible CTO Agent                  │
│                                                      │
│  1. Monitor  ──► Railway / Vercel Logs API          │
│  2. Analyze  ──► LLM (error classification)           │
│  3. Patch     ──► Write code fix (LLM + file ops)    │
│  4. Deploy   ──► railway redeploy / Vercel API      │
│  5. Verify   ──► Re-check logs + health endpoint     │
│  6. Loop     ──► If not fixed, retry w/ context      │
└──────────────────────────────────────────────────────┘
```

## Quick Start

```powershell
# 1. Link your Railway project
$env:RAILWAY_TOKEN = "your-railway-token"
$env:RAILWAY_PROJECT_ID = "your-project-id"

# 2. Run the monitor
.\scripts\monitor.ps1

# 3. Or run the full self-healing loop
.\scripts\heal.ps1 -Mode Full
```

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Railway | ✅ Primary | CLI-first, MCP available |
| Vercel | ✅ Secondary | REST API |
| Neon | 🔜 DB layer | Branching per deploy |

## Project Structure

```
invisible-cto/
├── scripts/
│   ├── monitor.ps1      # Log streaming + error detection
│   ├── heal.ps1         # Full self-healing loop
│   ├── railway_wrapper.ps1  # Railway CLI wrapper
│   ├── vercel_wrapper.ps1   # Vercel API wrapper
│   └── logger.ps1       # Centralized logging
├── logs/                 # Agent runtime logs
├── memory/               # Project state + API notes
└── README.md
```

## Development Status

**Phase:** 2 — Log Monitoring Loop  
**Last Updated:** 2026-03-24

See `memory/project_state.md` for detailed progress.
