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
  } | ConvertTo-Json -Depth 40

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
  throw "Shopify did not return an access token. Confirm the app is installed and has write_products scope."
}

$targetWidths = @("D - Standard", "2E - Wide", "4E - Extra Wide")

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
        name
        optionValues {
          name
        }
      }
      variants(first: 250) {
        nodes {
          id
          title
          price
          compareAtPrice
          taxable
          inventoryPolicy
          sku
          barcode
          selectedOptions {
            name
            value
          }
          inventoryItem {
            tracked
            requiresShipping
          }
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

$plans = @()

foreach ($product in @($productsData.products.nodes)) {
  if ($product.gender.value -ne "men" -or $product.title -notlike "*Gel*Nimbus*28*") {
    continue
  }

  $sizeOption = @($product.options | Where-Object { $_.name -eq "SIZE" }) | Select-Object -First 1
  $widthOption = @($product.options | Where-Object { $_.name -eq "WIDTH" }) | Select-Object -First 1

  if (-not $sizeOption -or -not $widthOption) {
    continue
  }

  $existing = @{}
  $baseBySize = @{}

  foreach ($variant in @($product.variants.nodes)) {
    $size = (@($variant.selectedOptions) | Where-Object { $_.name -eq "SIZE" } | Select-Object -First 1).value
    $width = (@($variant.selectedOptions) | Where-Object { $_.name -eq "WIDTH" } | Select-Object -First 1).value

    if ($size -and $width) {
      $existing["$size|$width"] = $true

      if (-not $baseBySize.ContainsKey($size) -or $width -eq "D - Standard") {
        $baseBySize[$size] = $variant
      }
    }
  }

  $variantsToCreate = @()
  $descriptions = @()

  foreach ($sizeValue in @($sizeOption.optionValues)) {
    $size = $sizeValue.name
    $base = $baseBySize[$size]

    if (-not $base) {
      continue
    }

    foreach ($width in $targetWidths) {
      if ($existing.ContainsKey("$size|$width")) {
        continue
      }

      $variantInput = @{
        optionValues = @(
          @{
            optionName = "SIZE"
            name = $size
          },
          @{
            optionName = "WIDTH"
            name = $width
          }
        )
        price = $base.price
        taxable = [bool]$base.taxable
        inventoryPolicy = "DENY"
        inventoryItem = @{
          tracked = $true
          requiresShipping = [bool]$base.inventoryItem.requiresShipping
        }
      }

      if ($base.compareAtPrice) {
        $variantInput.compareAtPrice = $base.compareAtPrice
      }

      $variantsToCreate += $variantInput
      $descriptions += "$size / $width"
    }
  }

  if ($variantsToCreate.Count -gt 0) {
    $plans += [pscustomobject]@{
      ProductId = $product.id
      Title = $product.title
      Handle = $product.handle
      Variants = $variantsToCreate
      Descriptions = $descriptions
    }
  }
}

if ($plans.Count -eq 0) {
  Write-Host "No missing men's Gel Nimbus 28 width variants found."
  exit 0
}

Write-Host "Planned zero-inventory men's width variants:"
foreach ($plan in $plans) {
  Write-Host "- $($plan.Title) [$($plan.Handle)]: $($plan.Variants.Count) variant(s)"
  $plan.Descriptions | ForEach-Object { Write-Host "  -> $_" }
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to create these variants with inventory tracking and zero inventory."
  exit 0
}

$createMutation = @"
mutation CreateVariants(`$productId: ID!, `$variants: [ProductVariantsBulkInput!]!) {
  productVariantsBulkCreate(productId: `$productId, variants: `$variants) {
    productVariants {
      id
      title
      inventoryQuantity
      inventoryItem {
        tracked
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

foreach ($plan in $plans) {
  Write-Host ""
  Write-Host "Creating $($plan.Variants.Count) variant(s) for $($plan.Handle)..."

  $result = Invoke-ShopifyGraphQL `
    -Query $createMutation `
    -Variables @{
      productId = $plan.ProductId
      variants = $plan.Variants
    } `
    -AccessToken $accessToken

  $errors = @($result.productVariantsBulkCreate.userErrors)

  if ($errors.Count -gt 0) {
    $errors | ForEach-Object {
      Write-Host "Error: $($_.message) [$($_.code)] field=$(@($_.field) -join '.')"
    }
    exit 1
  }

  foreach ($variant in @($result.productVariantsBulkCreate.productVariants)) {
    Write-Host "Created $($variant.title): inventoryQuantity=$($variant.inventoryQuantity), tracked=$($variant.inventoryItem.tracked)"
  }
}
