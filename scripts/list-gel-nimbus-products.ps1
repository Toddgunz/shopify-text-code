param(
  [string]$Search = "Women's Gel Nimbus 28"
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
query FindProducts(`$query: String!) {
  products(first: 20, query: `$query) {
    nodes {
      title
      handle
      tags
      seo {
        title
        description
      }
      options {
        name
        optionValues {
          name
        }
      }
      media(first: 5) {
        nodes {
          alt
        }
      }
      metafields(first: 20, namespace: "custom") {
        nodes {
          namespace
          key
          type
          value
        }
      }
      variants(first: 10) {
        nodes {
          title
          selectedOptions {
            name
            value
          }
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
  if ($product.tags) {
    Write-Host "  Tags: $(@($product.tags) -join ', ')"
  }
  if ($product.seo.title -or $product.seo.description) {
    Write-Host "  SEO title: $($product.seo.title)"
    Write-Host "  SEO description: $($product.seo.description)"
  }

  foreach ($option in $product.options) {
    $values = @($option.optionValues | ForEach-Object { $_.name }) -join ", "
    Write-Host "  Option $($option.name): $values"
  }

  foreach ($media in $product.media.nodes) {
    if ($media.alt) {
      Write-Host "  Media alt: $($media.alt)"
    }
  }

  foreach ($metafield in $product.metafields.nodes) {
    $value = $metafield.value

    if ($value.Length -gt 120) {
      $value = "$($value.Substring(0, 120))..."
    }

    Write-Host "  Metafield $($metafield.namespace).$($metafield.key) [$($metafield.type)]: $value"
  }

  foreach ($variant in $product.variants.nodes) {
    $selected = @($variant.selectedOptions | ForEach-Object { "$($_.name)=$($_.value)" }) -join "; "
    Write-Host "  Variant $($variant.title): $selected"
  }
}
