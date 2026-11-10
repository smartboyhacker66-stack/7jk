#!/usr/bin/env bash
# Screen-reader friendly deploy script for the OpenRouter MCP server.
# Plain text only: no colors, no spinners, no emoji, no cursor movement.
# Every message is a complete line that starts with its status:
# INFO, ASK, OK, WARN or ERROR.
#
# What it does:
#   1. Pushes this project to GitHub.
#   2. If you give it a Render API key, creates the Render service,
#      asks for your OpenRouter API key only at that moment, and waits until it is live.
#   3. Prints the final HTTPS MCP URL and the access token.
#
# Run:  bash deploy.sh

set -u

REPO_URL="https://github.com/smartboyhacker66-stack/7jk.git"
SERVICE_NAME="openrouter-mcp"
BRANCH="main"
RENDER_API="https://api.render.com/v1"

info() { printf 'INFO: %s\n' "$*"; }
ask()  { printf 'ASK: %s\n' "$*"; }
ok()   { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found. Please install it and run this script again."; }

cd "$(dirname "$0")" || die "Could not enter the script folder."

info "Step 1 of 4. Checking required tools."
need git
need curl
need python3
ok "git, curl and python3 are installed."

info "Step 2 of 4. Pushing the project to GitHub at $REPO_URL"
if [ ! -d .git ]; then
  git init -q || die "git init failed."
  ok "Created a new git repository."
fi
git checkout -q -B "$BRANCH" 2>/dev/null || git branch -M "$BRANCH"
git add -A
if git diff --cached --quiet; then
  info "No new changes to commit."
else
  git -c user.name="${GIT_AUTHOR_NAME:-OpenRouter MCP Deploy}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-deploy@example.invalid}" \
      commit -q -m "Deploy OpenRouter MCP server" || die "git commit failed."
  ok "Committed your files."
fi
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REPO_URL"
else
  git remote add origin "$REPO_URL"
fi
info "Pushing now. If your computer asks you to sign in to GitHub, complete that first."
if ! git push -u origin "$BRANCH"; then
  warn "The normal push was rejected, probably because the repository already has other commits."
  ask "Type YES and press Enter to overwrite the remote branch, or press Enter to stop."
  read -r answer
  if [ "$answer" = "YES" ]; then
    git push -u --force-with-lease origin "$BRANCH" || git push -u --force origin "$BRANCH" || die "Push failed. Check your GitHub sign-in and permissions."
  else
    die "Stopped. Nothing was overwritten."
  fi
fi
ok "The code is on GitHub."

info "Step 3 of 4. Creating the Render service."
info "Typing is hidden for secret keys. Nothing will be shown on screen while you type or paste. Press Enter when done."
ask "Paste your Render API key, or press Enter to skip. You can create one in the Render dashboard under Account Settings, then API Keys."
read -r -s RENDER_API_KEY
printf '\n'

if [ -z "${RENDER_API_KEY:-}" ]; then
  warn "No Render API key given, so the service cannot be created automatically."
  info "Manual option: open this address in your browser:"
  printf 'https://render.com/deploy?repo=%s\n' "${REPO_URL%.git}"
  info "Render will read render.yaml and ask you for OPENROUTER_API_KEY. MCP_AUTH_TOKEN is generated for you."
  info "When the service is live, your MCP URL will look like https://$SERVICE_NAME.onrender.com/mcp"
  info "Copy the exact address from the Render dashboard, because Render adds letters if the name is taken."
  exit 0
fi

render_call() {
  # usage: render_call METHOD PATH [json-body-from-stdin]
  local method="$1" path="$2"
  if [ "$method" = "GET" ]; then
    curl -sS -X GET "$RENDER_API$path" -H "Authorization: Bearer $RENDER_API_KEY" -H "Accept: application/json"
  else
    curl -sS -X "$method" "$RENDER_API$path" -H "Authorization: Bearer $RENDER_API_KEY" \
      -H "Accept: application/json" -H "Content-Type: application/json" --data-binary @-
  fi
}
export RENDER_API_KEY

OWNER_JSON="$(render_call GET "/owners?limit=1")" || die "Could not reach Render."
OWNER_ID="$(printf '%s' "$OWNER_JSON" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d[0]["owner"]["id"])
except Exception:
    print("")')"
[ -n "$OWNER_ID" ] || die "Render did not accept the API key. Response was: $OWNER_JSON"
ok "Render account found."

ask "Paste your OpenRouter API key. It is sent only to Render as a secret environment variable. Typing is hidden."
read -r -s OPENROUTER_API_KEY
printf '\n'
[ -n "${OPENROUTER_API_KEY:-}" ] || die "No OpenRouter key was entered."
export OPENROUTER_API_KEY

MCP_AUTH_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export MCP_AUTH_TOKEN OWNER_ID REPO_URL SERVICE_NAME BRANCH

BODY="$(python3 - <<'PY'
import json, os
print(json.dumps({
  "type": "web_service",
  "name": os.environ["SERVICE_NAME"],
  "ownerId": os.environ["OWNER_ID"],
  "repo": os.environ["REPO_URL"].removesuffix(".git"),
  "branch": os.environ["BRANCH"],
  "autoDeploy": "yes",
  "serviceDetails": {
    "runtime": "python",
    "plan": "free",
    "region": "oregon",
    "healthCheckPath": "/health",
    "envSpecificDetails": {
      "buildCommand": "pip install -r requirements.txt",
      "startCommand": "python server.py"
    }
  },
  "envVars": [
    {"key": "PYTHON_VERSION", "value": "3.12.8"},
    {"key": "OPENROUTER_API_KEY", "value": os.environ["OPENROUTER_API_KEY"]},
    {"key": "MCP_AUTH_TOKEN", "value": os.environ["MCP_AUTH_TOKEN"]}
  ]
}))
PY
)"

CREATE_JSON="$(printf '%s' "$BODY" | render_call POST "/services")" || die "Could not reach Render."
unset BODY OPENROUTER_API_KEY

PARSED="$(printf '%s' "$CREATE_JSON" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    s=d.get("service",d)
    print(s.get("id","")); print(s.get("serviceDetails",{}).get("url",""))
except Exception:
    print(""); print("")')"
SERVICE_ID="$(printf '%s' "$PARSED" | sed -n 1p)"
SERVICE_URL="$(printf '%s' "$PARSED" | sed -n 2p)"
if [ -z "$SERVICE_ID" ]; then
  die "Render could not create the service. Response was: $CREATE_JSON"
fi
ok "Render service created."

info "Step 4 of 4. Waiting for the first deploy. This usually takes two to five minutes. I will report every 15 seconds."
ATTEMPT=0
while [ "$ATTEMPT" -lt 60 ]; do
  ATTEMPT=$((ATTEMPT + 1))
  sleep 15
  if [ -n "$SERVICE_URL" ]; then
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "$SERVICE_URL/health" || true)"
  else
    CODE="000"
    SERVICE_URL="$(render_call GET "/services/$SERVICE_ID" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("serviceDetails",{}).get("url",""))
except Exception:
    print("")')"
  fi
  if [ "$CODE" = "200" ]; then
    ok "The server is live."
    break
  fi
  info "Not ready yet. Check $ATTEMPT of 60."
done

if [ "$CODE" != "200" ]; then
  warn "The server was not ready after 15 minutes. Check the logs in the Render dashboard."
fi

printf '\n'
printf 'FINAL MCP URL: %s/mcp\n' "$SERVICE_URL"
printf 'AUTH HEADER: Authorization: Bearer %s\n' "$MCP_AUTH_TOKEN"
printf 'Keep the token private. Anyone with it can spend your OpenRouter credits.\n'
info "In Claude, add this as a custom connector using the URL above, with the bearer token as the authorization value."
