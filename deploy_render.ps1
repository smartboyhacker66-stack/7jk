param(
  [Parameter(Mandatory = $true)][string]$RepoUrl,
  [string]$Branch = "main",
  [string]$ServiceName = "openrouter-mcp"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($level, $msg) { Write-Host ("{0}: {1}" -f $level, $msg) }

$renderKey = $env:RENDER_API_KEY
$orKey = $env:OPENROUTER_API_KEY
if (-not $renderKey -or -not $orKey) {
  Say "ERROR" "Both keys must be provided by the calling script."
  exit 1
}

$headers = @{ Authorization = "Bearer $renderKey"; Accept = "application/json" }
$api = "https://api.render.com/v1"

try {
  Say "INFO" "Looking up your Render account."
  $owners = Invoke-RestMethod -Method Get -Uri "$api/owners?limit=1" -Headers $headers
  $ownerId = $owners[0].owner.id
  if (-not $ownerId) { throw "No Render owner found." }
  Say "OK" "Render account found."

  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $token = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")

  $body = @{
    type = "web_service"
    name = $ServiceName
    ownerId = $ownerId
    repo = $RepoUrl -replace "\.git$", ""
    branch = $Branch
    autoDeploy = "yes"
    serviceDetails = @{
      runtime = "python"
      plan = "free"
      region = "oregon"
      healthCheckPath = "/health"
      envSpecificDetails = @{
        buildCommand = "pip install -r requirements.txt"
        startCommand = "python server.py"
      }
    }
    envVars = @(
      @{ key = "PYTHON_VERSION"; value = "3.12.8" },
      @{ key = "OPENROUTER_API_KEY"; value = $orKey },
      @{ key = "MCP_AUTH_TOKEN"; value = $token }
    )
  } | ConvertTo-Json -Depth 10

  Say "INFO" "Creating the Render service named $ServiceName."
  $resp = Invoke-RestMethod -Method Post -Uri "$api/services" -Headers $headers -ContentType "application/json" -Body $body
  $svc = if ($resp.service) { $resp.service } else { $resp }
  $serviceId = $svc.id
  $url = $svc.serviceDetails.url
  if (-not $serviceId) { throw "Render did not return a service id." }
  Say "OK" "Render service created."
}
catch {
  $detail = $_.ErrorDetails.Message
  if (-not $detail) { $detail = $_.Exception.Message }
  Say "ERROR" "Render request failed: $detail"
  exit 1
}

$live = $false
for ($i = 1; $i -le 60; $i++) {
  Start-Sleep -Seconds 15
  if (-not $url) {
    try {
      $s = Invoke-RestMethod -Method Get -Uri "$api/services/$serviceId" -Headers $headers
      $url = $s.serviceDetails.url
    } catch { }
  }
  if ($url) {
    try {
      $r = Invoke-WebRequest -Uri "$url/health" -UseBasicParsing -TimeoutSec 20
      if ($r.StatusCode -eq 200) { $live = $true; break }
    } catch { }
  }
  Say "INFO" "Not ready yet. Check $i of 60."
}

if ($live) { Say "OK" "The server is live." }
else { Say "WARN" "The server was not ready after 15 minutes. Check the logs in the Render dashboard." }

Write-Host ""
Write-Host "FINAL MCP URL: $url/mcp"
Write-Host "AUTH HEADER: Authorization: Bearer $token"
Write-Host "Keep the token private. Anyone with it can spend your OpenRouter credits."
Say "INFO" "In Claude, add a custom connector with the URL above and the bearer token as the authorization value."
exit 0
