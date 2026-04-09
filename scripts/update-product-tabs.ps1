param(
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
  param([string[]]$Paragraphs)

  $children = @()

  foreach ($paragraph in $Paragraphs) {
    if ([string]::IsNullOrWhiteSpace($paragraph)) {
      continue
    }

    $children += @{
      type = "paragraph"
      children = @(
        @{
          type = "text"
          value = $paragraph
        }
      )
    }
  }

  return @{
    type = "root"
    children = $children
  } | ConvertTo-Json -Depth 10 -Compress
}

function New-RichTextTextNode {
  param(
    [string]$Value,
    [bool]$Bold = $false
  )

  $node = @{
    type = "text"
    value = $Value
  }

  if ($Bold) {
    $node.bold = $true
  }

  return $node
}

function ConvertTo-ShopifyRichTextDocument {
  param(
    [array]$Nodes
  )

  return @{
    type = "root"
    children = $Nodes
  } | ConvertTo-Json -Depth 20 -Compress
}

function New-RichTextParagraph {
  param(
    [array]$Children
  )

  return @{
    type = "paragraph"
    children = $Children
  }
}

function New-RichTextBulletList {
  param(
    [array]$Items
  )

  $children = @()

  foreach ($item in $Items) {
    $children += @{
      type = "list-item"
      children = @(
        @{
          type = "paragraph"
          children = $item
        }
      )
    }
  }

  return @{
    type = "list"
    listType = "unordered"
    children = $children
  }
}

function Get-ContentSetForProduct {
  param(
    [string]$Title,
    [string]$Handle
  )

  $isWomen = $false

  if ($Title -like "Women*" -or $Handle -like "women-*") {
    $isWomen = $true
  }

  $productDetailsParagraphs = @(
    "The GEL-NIMBUS 28 is a max-cushion daily trainer built for soft landings and smooth, comfortable miles.",
    "FF BLAST PLUS cushioning and PureGEL technology work together to create a lightweight, cloud-like feel underfoot, while the engineered knit upper delivers a secure and breathable fit."
  )

  if ($isWomen) {
    $weightLabel = "8.5 oz / 242 g"
  } else {
    $weightLabel = "9.9 oz / 281 g"
  }

  $productDetailsNodes = @(
    (New-RichTextParagraph -Children @(
      New-RichTextTextNode -Value $productDetailsParagraphs[0]
    )),
    (New-RichTextParagraph -Children @(
      New-RichTextTextNode -Value $productDetailsParagraphs[1]
    ))
  )

  $techSpecsNodes = @(
    (New-RichTextBulletList -Items @(
      @(
        (New-RichTextTextNode -Value "Support: " -Bold $true),
        (New-RichTextTextNode -Value "Neutral")
      ),
      @(
        (New-RichTextTextNode -Value "Cushioning: " -Bold $true),
        (New-RichTextTextNode -Value "Maximum")
      ),
      @(
        (New-RichTextTextNode -Value "Heel drop: " -Bold $true),
        (New-RichTextTextNode -Value "8 mm")
      ),
      @(
        (New-RichTextTextNode -Value "Weight: " -Bold $true),
        (New-RichTextTextNode -Value $weightLabel)
      ),
      @(
        (New-RichTextTextNode -Value "Surface: " -Bold $true),
        (New-RichTextTextNode -Value "Road")
      ),
      @(
        (New-RichTextTextNode -Value "Midsole: " -Bold $true),
        (New-RichTextTextNode -Value "FF BLAST PLUS cushioning with PureGEL technology")
      )
    ))
  )

  return @{
    ProductDetails = (ConvertTo-ShopifyRichTextDocument -Nodes $productDetailsNodes)
    TechSpecs = (ConvertTo-ShopifyRichTextDocument -Nodes $techSpecsNodes)
    WeightLabel = $weightLabel
  }
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
      productDetails: metafield(namespace: "custom", key: "product_details") {
        id
        type
        value
      }
      techSpecs: metafield(namespace: "custom", key: "tech_specs") {
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

$products = @($productsData.products.nodes | Where-Object {
  $_.handle -like "*gel-nimbus-28*" -or $_.title -like "*Gel*Nimbus*28*"
})

if ($Handles.Count -gt 0) {
  $targets = @($products | Where-Object { $Handles -contains $_.handle })
} else {
  $targets = $products
}

if ($targets.Count -eq 0) {
  Write-Host "No matching products found for search '$Search'."
  exit 1
}

Write-Host "Target products:"
$targets | ForEach-Object {
  $contentSet = Get-ContentSetForProduct -Title $_.title -Handle $_.handle
  Write-Host "- $($_.title) [$($_.handle)] -> Tech Specs weight $($contentSet.WeightLabel)"
}

if (-not $Apply) {
  Write-Host ""
  Write-Host "Dry run only. Re-run with -Apply to write custom.product_details and custom.tech_specs."
  exit 0
}

$metafields = @()

foreach ($target in $targets) {
  $contentSet = Get-ContentSetForProduct -Title $target.title -Handle $target.handle

  $metafields += @{
    ownerId = $target.id
    namespace = "custom"
    key = "product_details"
    type = "rich_text_field"
    value = $contentSet.ProductDetails
  }

  $metafields += @{
    ownerId = $target.id
    namespace = "custom"
    key = "tech_specs"
    type = "rich_text_field"
    value = $contentSet.TechSpecs
  }
}

$setMetafieldsMutation = @"
mutation SetProductTabs(`$metafields: [MetafieldsSetInput!]!) {
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
Write-Host "Updated product_details and tech_specs on $($targets.Count) product(s)."
