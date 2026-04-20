# Invisible CTO — Project State
> Last updated: 2026-03-24

## Current Phase
**Phase 2: Log Monitoring Loop** — IN PROGRESS

## What's Built

### Scripts (Phase 1 + 2)
| File | Status | Description |
|------|--------|-------------|
| `scripts/logger.ps1` | ✅ Complete | Centralized logging with severity levels |
| `scripts/railway_wrapper.ps1` | ✅ Complete | Railway CLI wrapper with JSON log streaming |
| `scripts/monitor.ps1` | ✅ Complete | Real-time log monitor + FATAL/WARN detection |
| `scripts/heal.ps1` | ✅ Phase 3 skeleton | Self-healing loop with LLM patch writer |
| `scripts/vercel_wrapper.ps1` | 🔜 TODO | Vercel REST API wrapper |

### Key Features Implemented
- **Log streaming** — polls Railway logs every 5s, deduplicates
- **Error classification** — FATAL (auto-heal trigger) vs WARN (log only)
- **Crash incident tracking** — writes incidents to `logs/crash_incidents_*.json`
- **Heal queue** — `heal_queue.json` bridges monitor → heal agent
- **LLM integration** — Ollama (local) + OpenAI fallback for patch writing
- **Exponential backoff** — retry with 2^n * 5s delay
- **Escalation** — writes escalation JSON when max retries hit

## What's Missing / Blockers

### Phase 2 (Current)
- [ ] **Need Railway CLI installed** — `railway logs` command not verified on this machine
- [ ] Need to test real log output format (JSON vs plain text)
- [ ] Railway GraphQL API research incomplete (log streaming endpoint?)

### Phase 3 (Next)
- [ ] Code fix writer (needs git integration + file ops)
- [ ] Patch validation (lint + type-check before deploy)
- [ ] Neon DB branching for staging deployments

### Phase 4
- [ ] Post-deploy verification loop
- [ ] Deployment health score tracking
- [ ] Lock deployment after max retries

### Phase 5
- [ ] Web UI for onboarding vibe coders
- [ ] Telegram/Discord webhook for notifications
- [ ] CEO silent mode

## API Notes (from research)

### Railway CLI
- `railway logs --tail --json` — structured JSON logs (needs verification)
- `railway up --detach` — trigger deploy
- `railway deployment list --json` — list deployments
- `railway deployment redeploy <id> --detach` — redeploy specific
- Rate limits: unknown — need to test

### Railway GraphQL
- Endpoint: `https://backboard.railway.app/graphql`
- Needs `Authorization: Bearer <token>` header
- Potential for richer log streaming than CLI

### Vercel
- Logs: `GET /v2/deployments/{id}/events` (no raw production log stream)
- Deploy: `POST /v1/deployments/{id}/redeploy`
- Better for CI/CD than real-time self-healing

## Next Action
**TODAY:** Test `railway logs --tail` output format. Write `memory/railway_logs_sample.md` with actual output.
Then: connect real Railway project → run monitor.ps1 → verify crash detection works.

## Git Status
- Repo initialized locally
- No remote yet
- Push to GitHub via system PAT when Phase 2 + 3 tested
