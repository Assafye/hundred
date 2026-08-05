Param(
  [string]$ComposeFile = "scripts/staging/docker-compose.feed-staging.yml"
)

$required = @("FEED_REDIS_URL", "FEED_QDRANT_URL", "FEED_QDRANT_COLLECTION")
$missing = @()

foreach ($k in $required) {
  $value = [Environment]::GetEnvironmentVariable($k)
  if ([string]::IsNullOrWhiteSpace($value)) {
    $missing += $k
  }
}

if ($missing.Count -gt 0) {
  Write-Error ("Missing required env vars: " + ($missing -join ", "))
  exit 1
}

if (-not ($env:FEED_REDIS_URL.StartsWith("redis://") -or $env:FEED_REDIS_URL.StartsWith("rediss://"))) {
  Write-Error "FEED_REDIS_URL must be redis:// or rediss:// (UPSTASH_REDIS_REST_URL is not supported as direct transport)."
  exit 1
}

Write-Host "Starting feed staging stack..." -ForegroundColor Cyan
docker compose -f $ComposeFile up -d
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Feed API should be on http://localhost:8000 and Prometheus on http://localhost:9090" -ForegroundColor Green
