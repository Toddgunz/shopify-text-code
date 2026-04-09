param(
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

if ([string]::IsNullOrWhiteSpace($accessToken)) {
  throw "Shopify did not return an access token. Confirm the app is installed and has read_products/write_products scopes."
}

$widthNames = @{
  "D Medium" = "D - Standard"
  "2E Wide" = "2E - Wide"
  "4E Extra Wide" = "4E - Extra Wide"
}

$findProductsQuery = @"
query FindProducts(`$query: String!, `$first: Int!) {
  products(first: `$first, query: `$query) {
    nodes {
      id
      title
      handle
      gender: metafield(namespace: "custom", key: "gender") {
        value
      }
      options {
        id
        name
        position
        optionValues {
          id
          name
          hasVariants
        }
      }
    }
  }
}
"@

$productsData = Invoke-ShopifyGraphQL `
  -Query $findProductsQuery `
  -Variables @{ query = "Gel Nimbus 28"; first = 100 } `
  -AccessToken $accessToken

$targets = @()

foreach ($product in @($productsData.products.nodes)) {
  if ($product.gender.value -ne "men" -or $product.title -notlike "*Gel*Nimbus*28*") {
    continue
  }

  $widthOption = @($product.options | Where-Object { $_.name -eq "WIDTH" }) | Select-Object -First 1

  if (-not $widthOption) {
    continue
  }

  $updates = @()
  $currentOrder = @($widthOption.optionValues | ForEach-Object { $_.name }) -join ", "

  foreach ($optionValue in @($widthOption.optionValues)) {
    if ($widthNames.ContainsKey($optionValue.name)) {
      $updates += @{
        id = $optionValue.id
        name = $widthNames[$optionValue.name]
      }
    }
  }

  if ($updates.Count -gt 0) {
    $targets += [pscustomobject]@{
      ProductId = $product.id
      Title = $product.title
      Handle = $product.handle
      WidthOptionId = $widthOption.id
      CurrentOrder = $currentOrder
      Updates = $updates
    }
  }
}

if ($targets.Count -eq 0) {
  Write-Host "No men's Gel Nimbus 28 width changes needed."
  exit 0
}

Write-Host "Planned men's width option updates:"
$targets | ForEach-Object {
  Write-Host "- $($_.Title) [$($_.Handle)] current order: $($_.CurrentOrder)"
  foreach ($update in $_.Updates) {
    Write-Host "  -> $($update.name)"
  }
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to update width option labels."
  exit 0
}

$updateOptionMutation = @"
mutation UpdateWidthOption(
  `$productId: ID!,
  `$option: OptionUpdateInput!,
  `$optionValuesToUpdate: [OptionValueUpdateInput!]
) {
  productOptionUpdate(
    productId: `$productId,
    option: `$option,
    optionValuesToUpdate: `$optionValuesToUpdate
  ) {
    userErrors {
      field
      message
      code
    }
    product {
      id
      title
      handle
      options {
        name
        optionValues {
          name
        }
      }
    }
  }
}
"@

foreach ($target in $targets) {
  $result = Invoke-ShopifyGraphQL `
    -Query $updateOptionMutation `
    -Variables @{
      productId = $target.ProductId
      option = @{
        id = $target.WidthOptionId
      }
      optionValuesToUpdate = $target.Updates
    } `
    -AccessToken $accessToken

  $errors = @($result.productOptionUpdate.userErrors)

  if ($errors.Count -gt 0) {
    $errors | ForEach-Object {
      Write-Host "Error updating $($target.Handle): $($_.message) [$($_.code)]"
    }
    exit 1
  }

  $widthOption = @($result.productOptionUpdate.product.options | Where-Object { $_.name -eq "WIDTH" }) | Select-Object -First 1
  $newOrder = @($widthOption.optionValues | ForEach-Object { $_.name }) -join ", "
  Write-Host "Updated $($target.Handle): $newOrder"
}
