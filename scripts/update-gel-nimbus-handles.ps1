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

function ConvertTo-HandleSlug {
  param([string]$Text)

  $slug = $Text.ToLowerInvariant()
  $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-")
  $slug = [regex]::Replace($slug, "-+", "-")
  return $slug.Trim("-")
}

function Format-ColorName {
  param([string]$Text)

  $normalized = [regex]::Replace($Text.Trim(), "\s*/\s*", " / ")
  $normalized = [regex]::Replace($normalized, "\s+", " ")
  return (Get-Culture).TextInfo.ToTitleCase($normalized.ToLowerInvariant())
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
      color: metafield(namespace: "custom", key: "product_color") {
        value
      }
      gender: metafield(namespace: "custom", key: "gender") {
        value
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
  $gender = $product.gender.value
  $color = $product.color.value

  if ($product.title -notlike "*Gel*Nimbus*28*" -or [string]::IsNullOrWhiteSpace($color)) {
    continue
  }

  if ($gender -eq "men") {
    $prefix = "men"
    $displayColor = Format-ColorName -Text $color
  } elseif ($gender -eq "women") {
    $prefix = "women"
    $displayColor = $color
  } else {
    continue
  }

  $colorSlug = ConvertTo-HandleSlug -Text $displayColor
  $newHandle = "$prefix-gel-nimbus-28-$colorSlug"

  if ($product.handle -ne $newHandle -or $color -ne $displayColor) {
    $targets += [pscustomobject]@{
      Id = $product.id
      Title = $product.title
      OldHandle = $product.handle
      NewHandle = $newHandle
      Color = $color
      NewColor = $displayColor
      UpdateColor = ($color -ne $displayColor)
      UpdateHandle = ($product.handle -ne $newHandle)
    }
  }
}

if ($targets.Count -eq 0) {
  Write-Host "No handle changes needed."
  exit 0
}

Write-Host "Planned handle changes:"
$targets | ForEach-Object {
  $colorNote = if ($_.UpdateColor) { " and color '$($_.Color)' -> '$($_.NewColor)'" } else { "" }
  $handleNote = if ($_.UpdateHandle) { "$($_.OldHandle) -> $($_.NewHandle)" } else { "handle unchanged" }
  Write-Host "- $($_.Title) / $($_.NewColor): $handleNote$colorNote"
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to update handles."
  exit 0
}

$productUpdateMutation = @"
mutation UpdateProductHandle(`$product: ProductUpdateInput!) {
  productUpdate(product: `$product) {
    product {
      id
      title
      handle
    }
    userErrors {
      field
      message
    }
  }
}
"@

$metafieldsSetMutation = @"
mutation SetProductColor(`$metafields: [MetafieldsSetInput!]!) {
  metafieldsSet(metafields: `$metafields) {
    metafields {
      id
      key
      value
    }
    userErrors {
      field
      message
      code
    }
  }
}
"@

foreach ($target in $targets) {
  if ($target.UpdateColor) {
    $colorResult = Invoke-ShopifyGraphQL `
      -Query $metafieldsSetMutation `
      -Variables @{
        metafields = @(
          @{
            ownerId = $target.Id
            namespace = "custom"
            key = "product_color"
            type = "single_line_text_field"
            value = $target.NewColor
          }
        )
      } `
      -AccessToken $accessToken

    $colorErrors = @($colorResult.metafieldsSet.userErrors)

    if ($colorErrors.Count -gt 0) {
      $colorErrors | ForEach-Object {
        Write-Host "Error updating color for $($target.OldHandle): $($_.message) [$($_.code)]"
      }
      exit 1
    }

    Write-Host "Updated color for $($target.OldHandle): $($target.NewColor)"
  }

  if ($target.UpdateHandle) {
    $result = Invoke-ShopifyGraphQL `
      -Query $productUpdateMutation `
      -Variables @{
        product = @{
          id = $target.Id
          handle = $target.NewHandle
        }
      } `
      -AccessToken $accessToken

    $errors = @($result.productUpdate.userErrors)

    if ($errors.Count -gt 0) {
      $errors | ForEach-Object {
        Write-Host "Error updating $($target.OldHandle): $($_.message)"
      }
      exit 1
    }

    Write-Host "Updated handle $($target.OldHandle) -> $($result.productUpdate.product.handle)"
  }
}
