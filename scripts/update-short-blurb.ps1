param(
  [string]$Blurb = "Plush cushioning and smooth landings for everyday training miles.",
  [string]$Search = "Gel Nimbus 28",
  [string[]]$Handles = @(),
  [switch]$Apply
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

if ([string]::IsNullOrWhiteSpace($store) -or [string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
  throw ".env must include SHOPIFY_STORE, SHOPIFY_CLIENT_ID, and SHOPIFY_CLIENT_SECRET."
}

function Invoke-ShopifyGraphQL {
  param(
    [string]$Query,
    [hashtable]$Variables,
    [string]$AccessToken
  )

  $body = @{
    query = $Query
    variables = $Variables
  } | ConvertTo-Json -Depth 25

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "https://$store/admin/api/2026-01/graphql.json" `
    -Headers @{
      "Content-Type" = "application/json"
      "X-Shopify-Access-Token" = $AccessToken
    } `
    -Body $body

  if ($response.errors) {
    $messages = ($response.errors | ConvertTo-Json -Depth 10)
    throw "Shopify GraphQL returned errors: $messages"
  }

  return $response.data
}

function ConvertTo-ShopifyRichTextValue {
  param([string]$Text)

  return @{
    type = "root"
    children = @(
      @{
        type = "paragraph"
        children = @(
          @{
            type = "text"
            value = $Text
          }
        )
      }
    )
  } | ConvertTo-Json -Depth 10 -Compress
}

$tokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "https://$store/admin/oauth/access_token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type = "client_credentials"
    client_id = $clientId
    client_secret = $clientSecret
  }

$accessToken = $tokenResponse.access_token

if ([string]::IsNullOrWhiteSpace($accessToken)) {
  throw "Shopify did not return an access token. Confirm the app is installed and has read_products/write_products scopes."
}

$findProductsQuery = @"
query FindProducts(`$query: String!, `$first: Int!) {
  products(first: `$first, query: `$query) {
    nodes {
      id
      title
      handle
      metafield(namespace: "custom", key: "short_blurb") {
        id
        type
        value
      }
    }
  }
}
"@

$productsData = Invoke-ShopifyGraphQL `
  -Query $findProductsQuery `
  -Variables @{ query = $Search; first = 50 } `
  -AccessToken $accessToken

$products = @($productsData.products.nodes)

if ($Handles.Count -gt 0) {
  $targets = @($products | Where-Object { $Handles -contains $_.handle })
} else {
  $targets = @($products | Where-Object {
    $_.handle -like "*gel-nimbus-28*" -or $_.title -like "*Gel*Nimbus*28*"
  })
}

if ($targets.Count -eq 0) {
  Write-Host "No matching products found for search '$Search'."
  exit 1
}

Write-Host "Target products:"
$targets | ForEach-Object {
  $current = if ($_.metafield) { "existing $($_.metafield.type)" } else { "no current short_blurb" }
  Write-Host "- $($_.title) [$($_.handle)] ($current)"
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to write custom.short_blurb."
  exit 0
}

$richTextValue = ConvertTo-ShopifyRichTextValue -Text $Blurb
$metafields = @($targets | ForEach-Object {
  @{
    ownerId = $_.id
    namespace = "custom"
    key = "short_blurb"
    type = "rich_text_field"
    value = $richTextValue
  }
})

$setMetafieldsMutation = @"
mutation SetShortBlurbs(`$metafields: [MetafieldsSetInput!]!) {
  metafieldsSet(metafields: `$metafields) {
    metafields {
      id
      namespace
      key
      type
      owner {
        ... on Product {
          title
          handle
        }
      }
    }
    userErrors {
      field
      message
      code
    }
  }
}
"@

$result = Invoke-ShopifyGraphQL `
  -Query $setMetafieldsMutation `
  -Variables @{ metafields = $metafields } `
  -AccessToken $accessToken

$errors = @($result.metafieldsSet.userErrors)

if ($errors.Count -gt 0) {
  $errors | ForEach-Object {
    Write-Host "Error: $($_.message) [$($_.code)]"
  }
  exit 1
}

Write-Host ""
Write-Host "Updated custom.short_blurb on $($result.metafieldsSet.metafields.Count) product(s)."
