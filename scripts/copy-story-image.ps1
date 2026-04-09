param(
  [string]$SourceHandle = "men-gel-nimbus-28-cloud-grey-cream",
  [string]$Search = "Gel Nimbus 28",
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

$findProductsQuery = @"
query FindProducts(`$query: String!, `$first: Int!) {
  products(first: `$first, query: `$query) {
    nodes {
      id
      title
      handle
      storyImage: metafield(namespace: "custom", key: "story_image") {
        value
      }
      storyImageMobile: metafield(namespace: "custom", key: "story_image_mobile") {
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

$products = @($productsData.products.nodes | Where-Object {
  $_.handle -like "*gel-nimbus-28*" -or $_.title -like "*Gel*Nimbus*28*"
})

$source = @($products | Where-Object { $_.handle -eq $SourceHandle }) | Select-Object -First 1

if (-not $source) {
  throw "Source product '$SourceHandle' was not found in the results for '$Search'."
}

if ([string]::IsNullOrWhiteSpace($source.storyImage.value)) {
  throw "Source product '$SourceHandle' does not have custom.story_image set."
}

$targets = @($products | Where-Object { $_.handle -ne $SourceHandle })

Write-Host "Source image product:"
Write-Host "- $($source.title) [$($source.handle)]"
Write-Host "  story_image=$($source.storyImage.value)"
if ($source.storyImageMobile.value) {
  Write-Host "  story_image_mobile=$($source.storyImageMobile.value)"
}

Write-Host ""
Write-Host "Target products:"
$targets | ForEach-Object {
  Write-Host "- $($_.title) [$($_.handle)]"
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to copy custom.story_image to the other Gel Nimbus 28 products."
  exit 0
}

$metafields = @()

foreach ($target in $targets) {
  $metafields += @{
    ownerId = $target.id
    namespace = "custom"
    key = "story_image"
    type = "file_reference"
    value = $source.storyImage.value
  }

  if (-not [string]::IsNullOrWhiteSpace($source.storyImageMobile.value)) {
    $metafields += @{
      ownerId = $target.id
      namespace = "custom"
      key = "story_image_mobile"
      type = "file_reference"
      value = $source.storyImageMobile.value
    }
  }
}

$setMetafieldsMutation = @"
mutation CopyStoryImage(`$metafields: [MetafieldsSetInput!]!) {
  metafieldsSet(metafields: `$metafields) {
    metafields {
      id
      namespace
      key
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
Write-Host "Copied story image metafields to $($targets.Count) product(s)."
