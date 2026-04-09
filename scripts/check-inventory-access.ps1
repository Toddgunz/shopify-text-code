param(
  [string]$Search = "Gel Nimbus 28"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot ".env"

if (-not (Test-Path -LiteralPath $envPath)) {
  throw "Missing .env. Add SHOPIFY_STORE, SHOPIFY_CLIENT_ID, and SHOPIFY_CLIENT_SECRET first."
}

Get-Content -LiteralPath $envPath | ForEach-Object {
  if ($_ -match "^\s*#" -or $_ -notmatch "=") {
    return
  }

  $name, $value = $_ -split "=", 2
  [Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), "Process")
}

$store = $env:SHOPIFY_STORE
$clientId = $env:SHOPIFY_CLIENT_ID
$clientSecret = $env:SHOPIFY_CLIENT_SECRET

$tokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "https://$store/admin/oauth/access_token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type = "client_credentials"
    client_id = $clientId
    client_secret = $clientSecret
  }

$query = @"
query CheckInventory(`$query: String!) {
  products(first: 5, query: `$query) {
    nodes {
      title
      handle
      variants(first: 100) {
        nodes {
          title
          inventoryQuantity
        }
      }
    }
  }
}
"@

$body = @{
  query = $query
  variables = @{ query = $Search }
} | ConvertTo-Json -Depth 20

$response = Invoke-RestMethod `
  -Method Post `
  -Uri "https://$store/admin/api/2026-01/graphql.json" `
  -Headers @{
    "Content-Type" = "application/json"
    "X-Shopify-Access-Token" = $tokenResponse.access_token
  } `
  -Body $body

if ($response.errors) {
  $response.errors | ConvertTo-Json -Depth 10
  exit 1
}

foreach ($product in $response.data.products.nodes) {
  Write-Host "$($product.title) [$($product.handle)]"
  foreach ($variant in $product.variants.nodes) {
    Write-Host "  $($variant.title): inventoryQuantity=$($variant.inventoryQuantity)"
  }
}
