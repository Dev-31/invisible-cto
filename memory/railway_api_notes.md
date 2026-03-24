# Railway API Notes — Verified 2026-03-24
> Based on actual Railway CLI testing against buildshield project

## Railway CLI Commands (VERIFIED)

### Authentication
```powershell
railway whoami
# Output: "Logged in as Dev Sopariwala (devsopariwala22@gmail.com)"

railway login   # Interactive login
railway logout  # Clear session
```

### Project & Service
```powershell
# List projects (JSON)
railway project list --json
# Returns: id, name, createdAt, environments[].id, services[].id

# Link project to current directory
railway link --project <project-id>
# Prompt: select workspace → project → environment

# Status (linked project)
railway status

# Switch service
railway service <service-id-or-name>
```

### Log Streaming (VERIFIED WORKING)
```powershell
# JSON logs — single fetch
railway logs --service "theBuildShield.com" --json --lines 100

# JSON logs — filter by error level
railway logs --service "theBuildShield.com" --json --lines 100 --filter "@level:error"

# Time-based filtering
railway logs --service "theBuildShield.com" --json --lines 50 --since 30m
railway logs --service "theBuildShield.com" --json --since 1h --until 10m

# Stream live (default = streams until Ctrl+C)
railway logs --service "theBuildShield.com" --json

# Build logs
railway logs --service "theBuildShield.com" --build --json --lines 50

# Deployment logs
railway logs --service "theBuildShield.com" --deployment --json --lines 50
```

### JSON Log Format (VERIFIED)
```json
// Standard log line
{
  "timestamp": "2026-03-20T14:24:09.006255019Z",
  "level": "info",           // lowercase! (info, error, warn, debug)
  "message": "Starting Container"
}

// Request log (structured)
{
  "timestamp": "2026-03-20T14:24:13.443821Z",
  "level": "info",
  "message": "",
  "event": "request_completed",
  "method": "GET",
  "path": "/healthz",
  "status_code": 200,
  "duration_ms": 1.34,
  "correlation_id": "6c5f808b-5150-4adc-a291-3c543baafb23",
  "logger": "app.main"
}

// Sentry disabled event
{
  "timestamp": "2026-03-20T14:24:13.028968Z",
  "level": "info",
  "message": "",
  "event": "sentry_disabled",
  "reason": "SENTRY_DSN not configured",
  "logger": "app.main"
}
```

### IMPORTANT: `level` Field Unreliability
Railway's `level` field is unreliable for some frameworks.  
Example: Uvicorn INFO lines (`"INFO: Started server process"`) come through as `"level": "error"`.

**Rule:** Always parse `message` content, don't trust `level` alone for crash detection.

### Crash Detection Patterns (from real logs)
```powershell
# These patterns detected in buildshield logs:
"DeprecationWarning"     # WARN level
"FastAPIDeprecationWarning"  # ERROR level but not a crash
"Started server process" # INFO (Uvicorn) — NOT a crash
"Application startup complete" # INFO — NOT a crash

# Real crash indicators to watch for:
"ECONNREFUSED"           # Database/service connection refused
"Connection refused"
"Error:"                  # Python error
"Traceback"              # Exception stack trace
"500 Internal Server Error"
"503 Service Unavailable"
"timeout"
"refused to connect"
"SQLite error"           # Database errors
"UnicodeDecodeError"
"KeyError"
"ValueError"
"AttributeError"
```

### Deploy Operations
```powershell
# Upload and deploy current directory
railway up --detach

# Redeploy latest deployment
railway redeploy

# Restart without rebuilding (faster)
railway restart

# List deployments
railway deployment list --json
```

### Environment Variables
```powershell
# Set variable
railway variables set API_KEY=mykey --service "theBuildShield.com"

# List variables
railway variables list --json

# Delete variable
railway variables unset API_KEY
```

### Project IDs (buildshield)
- **Workspace ID:** `1b4aba4d-c1db-4ebf-bb56-3decfa41a48c`
- **Project ID:** `ef8611ee-80b9-4233-b048-0463a39aa4c8`
- **Production Env ID:** `0066b603-0541-42e1-8f6c-56eac1a7eb23`
- **Service ID:** `18c404b4-b27e-492e-a460-4d07a7c160d9`

## Railway GraphQL API
- **Endpoint:** `https://backboard.railway.app/graphql`
- **Auth:** `Authorization: Bearer <token>`
- Not yet tested — may enable richer log queries than CLI
- TODO: Test GraphQL log subscription (websocket? HTTP polling?)

## Rate Limits
- Unknown — CLI does not document limits
- `railway up --detach` is non-blocking, safe for automation
- Limit polling to every 5s minimum for log streaming

## Vercel API (Secondary)
See roadmap for preliminary research. Not tested yet.

## Next Test Items
1. Test `railway redeploy` — does it work? What's the output?
2. Test GraphQL log subscription
3. Test Neon DB branching for staging envs
4. Verify Railway MCP server (claude code plugin)
