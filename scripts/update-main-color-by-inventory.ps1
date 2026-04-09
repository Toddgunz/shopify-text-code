param(
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
  } | ConvertTo-Json -Depth 30

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
  throw "Shopify did not return an access token. Confirm the app is installed and has read_products/write_products/read_inventory scopes."
}

$findProductsQuery = @"
query FindProducts(`$query: String!, `$first: Int!) {
  products(first: `$first, query: `$query) {
    nodes {
      id
      title
      handle
      tags
      color: metafield(namespace: "custom", key: "product_color") {
        value
      }
      siblingCollection: metafield(namespace: "custom", key: "sibling_collection") {
        value
      }
      variants(first: 100) {
        nodes {
          inventoryQuantity
        }
      }
    }
  }
}
"@

$productsData = Invoke-ShopifyGraphQL `
  -Query $findProductsQuery `
  -Variables @{ query = $Search; first = 100 } `
  -AccessToken $accessToken

$products = @($productsData.products.nodes | Where-Object {
  $_.siblingCollection.value -and $_.color.value
})

if ($products.Count -eq 0) {
  Write-Host "No products with custom.sibling_collection and custom.product_color found for '$Search'."
  exit 1
}

$groups = $products | Group-Object { $_.siblingCollection.value }
$changes = @()

foreach ($group in $groups) {
  $items = @($group.Group | ForEach-Object {
    $quantity = 0

    foreach ($variant in @($_.variants.nodes)) {
      $quantity += [int]$variant.inventoryQuantity
    }

    [pscustomobject]@{
      Id = $_.id
      Title = $_.title
      Handle = $_.handle
      Color = $_.color.value
      Tags = @($_.tags)
      Quantity = $quantity
      IsMainColor = (@($_.tags) -contains "main-color")
    }
  })

  $sorted = @($items | Sort-Object -Property @{ Expression = "Quantity"; Descending = $true }, @{ Expression = "Handle"; Descending = $false })
  $topQuantity = $sorted[0].Quantity
  $topItems = @($items | Where-Object { $_.Quantity -eq $topQuantity })
  $currentMain = @($items | Where-Object { $_.IsMainColor })

  Write-Host ""
  Write-Host "Sibling group: $($group.Name)"
  $items | Sort-Object -Property Quantity -Descending | ForEach-Object {
    $marker = if ($_.IsMainColor) { " current-main" } else { "" }
    Write-Host "- $($_.Handle) [$($_.Color)]: qty=$($_.Quantity)$marker"
  }

  if ($topItems.Count -gt 1) {
    $currentMainAtTop = @($currentMain | Where-Object { $_.Quantity -eq $topQuantity })

    if ($currentMainAtTop.Count -eq 1) {
      $winner = $currentMainAtTop[0]
      Write-Host "Tie at $topQuantity; keeping current main-color: $($winner.Handle)"
    } else {
      Write-Host "Tie at $topQuantity with no single current main-color winner; no changes planned for this group."
      continue
    }
  } else {
    $winner = $topItems[0]
  }

  foreach ($item in $items) {
    $shouldHaveMainColor = ($item.Id -eq $winner.Id)

    if ($item.IsMainColor -ne $shouldHaveMainColor) {
      $newTags = @($item.Tags | Where-Object { $_ -ne "main-color" })

      if ($shouldHaveMainColor) {
        $newTags += "main-color"
      }

      $changes += [pscustomobject]@{
        Id = $item.Id
        Handle = $item.Handle
        Color = $item.Color
        Quantity = $item.Quantity
        Action = if ($shouldHaveMainColor) { "add main-color" } else { "remove main-color" }
        Tags = $newTags
      }
    }
  }
}

if ($changes.Count -eq 0) {
  Write-Host ""
  Write-Host "No main-color tag changes needed."
  exit 0
}

Write-Host ""
Write-Host "Planned tag changes:"
$changes | ForEach-Object {
  Write-Host "- $($_.Action): $($_.Handle) [$($_.Color)] qty=$($_.Quantity)"
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to update main-color tags."
  exit 0
}

$productUpdateMutation = @"
mutation UpdateProductTags(`$product: ProductUpdateInput!) {
  productUpdate(product: `$product) {
    product {
      id
      handle
      tags
    }
    userErrors {
      field
      message
    }
  }
}
"@

foreach ($change in $changes) {
  $result = Invoke-ShopifyGraphQL `
    -Query $productUpdateMutation `
    -Variables @{
      product = @{
        id = $change.Id
        tags = $change.Tags
      }
    } `
    -AccessToken $accessToken

  $errors = @($result.productUpdate.userErrors)

  if ($errors.Count -gt 0) {
    $errors | ForEach-Object {
      Write-Host "Error updating $($change.Handle): $($_.message)"
    }
    exit 1
  }

  Write-Host "Updated $($change.Handle): $($change.Action)"
}
