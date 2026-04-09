param(
  [string]$Handle = "women-gel-nimbus-28-black-feather-grey",
  [string]$VariantId = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot ".env"

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
query GetProduct(`$handle: String!) {
  productByHandle(handle: `$handle) {
    title
    handle
    options {
      name
      optionValues {
        name
        hasVariants
      }
    }
    variants(first: 100) {
      nodes {
        id
        title
        availableForSale
        inventoryQuantity
        selectedOptions {
          name
          value
        }
      }
    }
  }
}
"@

$body = @{
  query = $query
  variables = @{ handle = $Handle }
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

$product = $response.data.productByHandle
Write-Host "$($product.title) [$($product.handle)]"

foreach ($variant in $product.variants.nodes) {
  $selected = @($variant.selectedOptions | ForEach-Object { "$($_.name)=$($_.value)" }) -join "; "
  Write-Host "$($variant.title): availableForSale=$($variant.availableForSale), inventoryQuantity=$($variant.inventoryQuantity), $selected, id=$($variant.id)"
}

Write-Host ""
Write-Host "Option values:"
foreach ($option in $product.options) {
  $values = @($option.optionValues | ForEach-Object { "$($_.name) (hasVariants=$($_.hasVariants))" }) -join ", "
  Write-Host "$($option.name): $values"
}
