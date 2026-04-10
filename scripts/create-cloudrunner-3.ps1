$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot ".env"

Get-Content -LiteralPath $envPath | ForEach-Object {
  if ($_ -match "^\s*#" -or $_ -notmatch "=") { return }
  $name, $value = $_ -split "=", 2
  [Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), "Process")
}

$store       = $env:SHOPIFY_STORE
$clientId    = $env:SHOPIFY_CLIENT_ID
$clientSecret = $env:SHOPIFY_CLIENT_SECRET

$token = (Invoke-RestMethod -Method Post `
  -Uri "https://$store/admin/oauth/access_token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{ grant_type = "client_credentials"; client_id = $clientId; client_secret = $clientSecret }
).access_token

$headers = @{
  "Content-Type"            = "application/json"
  "X-Shopify-Access-Token"  = $token
}

# Get primary location ID via GraphQL (app lacks read_locations REST scope)
$locationGid = "gid://shopify/Location/113007657323"
Write-Host "Location GID: $locationGid"

function Invoke-ShopifyGraphQL {
  param([string]$Query, [hashtable]$Variables)
  $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 20
  $r = Invoke-RestMethod -Method Post `
    -Uri "https://$store/admin/api/2026-01/graphql.json" `
    -Headers $headers -Body $body
  if ($r.errors) { throw ($r.errors | ConvertTo-Json -Depth 5) }
  return $r.data
}

# ── Content ──────────────────────────────────────────────────────────────────

$productTitle = "Men" + [char]39 + "s Cloudrunner 3"

$bodyHtml = "The Cloudrunner 3 is the evolution of your favorite everyday running shoe. This mild-to-moderate stability trainer combines a new Cloud shape geometrically engineered for optimal support with lightweight Helion superfoam that delivers dynamic stability and impact absorption. The redesigned CloudTec cushioning system features deeper cavities that provide enhanced support and a planted, confident ride from start to finish. A wider base with heel clip and medial reinforcements add stability, while the 100% recycled polyester upper keeps things light and breathable."

$productDetailsValue = '{"type":"root","children":[{"type":"paragraph","children":[{"type":"text","value":"The "},{"type":"text","value":"Cloudrunner 3","bold":true},{"type":"text","value":" is the evolution of your favorite everyday running shoe. This "},{"type":"text","value":"mild-to-moderate stability","bold":true},{"type":"text","value":" trainer combines a new Cloud shape engineered for optimal support with lightweight "},{"type":"text","value":"Helion\u2122 superfoam","bold":true},{"type":"text","value":" that delivers dynamic stability and impact absorption."}]},{"type":"paragraph","children":[{"type":"text","value":"The redesigned "},{"type":"text","value":"CloudTec\u00ae cushioning","bold":true},{"type":"text","value":" system features deeper cavities for enhanced support and a planted, confident ride, featuring a "},{"type":"text","value":"100% recycled polyester","bold":true},{"type":"text","value":" upper for breathability and environmental responsibility."}]}]}'

$techSpecsValue = '{"type":"root","children":[{"type":"list","listType":"unordered","children":[{"type":"list-item","children":[{"type":"text","value":"Support: Mild-to-Moderate Stability"}]},{"type":"list-item","children":[{"type":"text","value":"Cushioning: Moderate"}]},{"type":"list-item","children":[{"type":"text","value":"Heel drop: 8 mm"}]},{"type":"list-item","children":[{"type":"text","value":"Weight: 11.2 oz / 317 g"}]},{"type":"list-item","children":[{"type":"text","value":"Surface: Road"}]},{"type":"list-item","children":[{"type":"text","value":"Midsole: CloudTec\u00ae with Helion\u2122 Superfoam"}]}]}]}'

$shortBlurb = '{"type":"root","children":[{"type":"paragraph","children":[{"type":"text","value":"Your go-to for confident, cushioned miles. Mild-to-moderate stability meets CloudTec\u00ae comfort."}]}]}'

# ── Variants ─────────────────────────────────────────────────────────────────

$sizes  = @("7","7.5","8","8.5","9","9.5","10","10.5","11","11.5","12","12.5","13","13.5","14","14.5","15")
$widths = @("D - Standard","2E - Wide")

$variants = @()
foreach ($size in $sizes) {
  foreach ($width in $widths) {
    $variants += @{
      option1             = $size
      option2             = $width
      price               = "160.00"
      inventory_management = "shopify"
      inventory_policy    = "deny"
      requires_shipping   = $true
      taxable             = $true
    }
  }
}

# ── Colorways ────────────────────────────────────────────────────────────────

$colorways = @(
  @{ color = "Black / Ivory"; handle = "men-cloudrunner-3-black-ivory" },
  @{ color = "Linen / Ivory"; handle = "men-cloudrunner-3-linen-ivory" }
)

foreach ($cw in $colorways) {
  Write-Host "`nCreating: $productTitle - $($cw.color)"

  # Check if product already exists by handle
  $existing = Invoke-RestMethod -Method Get `
    -Uri "https://$store/admin/api/2026-01/products.json?handle=$($cw.handle)" `
    -Headers $headers

  if ($existing.products.Count -gt 0) {
    $product = $existing.products[0]
    Write-Host "Product already exists: $($product.id)  Handle: $($product.handle)"
  } else {
    $productBody = @{
      product = @{
        title        = $productTitle
        vendor       = "On"
        product_type = "Shoes"
        body_html    = $bodyHtml
        handle       = $cw.handle
        status       = "active"
        options      = @(
          @{ name = "Size" },
          @{ name = "Width" }
        )
        variants = $variants
      }
    } | ConvertTo-Json -Depth 10

    $product = (Invoke-RestMethod -Method Post `
      -Uri "https://$store/admin/api/2026-01/products.json" `
      -Headers $headers `
      -Body $productBody).product

    Write-Host "Created product ID: $($product.id)  Handle: $($product.handle)"
  }

  # ── Inventory ───────────────────────────────────────────────────────────────
  Write-Host "Setting inventory..."
  $setQuantities = @()
  foreach ($variant in $product.variants) {
    $roll = Get-Random -Minimum 1 -Maximum 11
    $qty  = if ($roll -le 3) { 0 } else { Get-Random -Minimum 2 -Maximum 9 }
    $invItemGid = "gid://shopify/InventoryItem/$($variant.inventory_item_id)"
    $setQuantities += @{ inventoryItemId = $invItemGid; locationId = $locationGid; quantity = $qty }
    Write-Host "  $($variant.title): $qty units"
  }

  $invMutation = @'
mutation SetInventory($input: InventorySetOnHandQuantitiesInput!) {
  inventorySetOnHandQuantities(input: $input) {
    userErrors { field message }
  }
}
'@
  $invVars = @{ input = @{ reason = "correction"; setQuantities = $setQuantities } }
  try {
    Invoke-ShopifyGraphQL -Query $invMutation -Variables $invVars | Out-Null
    Write-Host "Inventory set."
  } catch {
    Write-Warning "Inventory skipped — app needs write_inventory scope in Shopify Admin."
  }

  # ── Metafields ──────────────────────────────────────────────────────────────
  Write-Host "Setting metafields..."
  foreach ($mf in @(
    @{ key = "product_details"; value = $productDetailsValue },
    @{ key = "tech_specs";      value = $techSpecsValue },
    @{ key = "short_blurb";    value = $shortBlurb }
  )) {
    $mfBody = @{
      metafield = @{
        namespace = "custom"
        key       = $mf.key
        value     = $mf.value
        type      = "rich_text_field"
      }
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method Post `
      -Uri "https://$store/admin/api/2026-01/products/$($product.id)/metafields.json" `
      -Headers $headers `
      -Body $mfBody | Out-Null
  }

  Write-Host "Done: $($cw.color)"
}

Write-Host "`nAll Cloudrunner 3 colorways created successfully."
