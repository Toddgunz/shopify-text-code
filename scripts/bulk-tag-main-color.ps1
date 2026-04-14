# bulk-tag-main-color.ps1
# Adds the 'main-color' tag to specific products by handle.
# Edit $targetHandles to include whichever products you want tagged.
# Any handle NOT in the list is left untouched.

$env_file = Join-Path $PSScriptRoot "..\..\.env"
if (!(Test-Path $env_file)) { $env_file = Join-Path $PSScriptRoot "..\.env" }
if (!(Test-Path $env_file)) { $env_file = "C:\Users\millc\OneDrive\Documents\ClaudeCode\.env" }

$envVars = @{}
Get-Content $env_file | ForEach-Object {
    if ($_ -match "^([^#][^=]*)=(.*)$") {
        $envVars[$matches[1].Trim()] = $matches[2].Trim().Trim('"')
    }
}

$store    = $envVars["SHOPIFY_STORE"]
$token    = $envVars["SHOPIFY_ACCESS_TOKEN"]
$headers  = @{ "X-Shopify-Access-Token" = $token; "Content-Type" = "application/json" }
$base     = "https://$store/admin/api/2026-01"

# ------------------------------------------------------------
# EDIT THIS LIST — add the handles of products that should
# receive the 'main-color' tag. Leave out any you want to skip.
# ------------------------------------------------------------
$targetHandles = @(
    # Men's Gel-Nimbus 28 - add whichever colorway is your default
    # "mens-gel-nimbus-28-black-white"

    # Men's Cloudrunner 3
    # "mens-on-cloudrunner-3-black-ivory"

    # Women's Cloudrunner 3
    # "womens-on-cloudrunner-3-linen-ivory"

    # Add more handles here...
)
# ------------------------------------------------------------

if ($targetHandles.Count -eq 0) {
    Write-Host "No handles listed in `$targetHandles. Edit the script and add product handles." -ForegroundColor Yellow
    exit
}

$tag = "main-color"
$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($handle in $targetHandles) {
    Write-Host "Processing: $handle" -NoNewline

    # Look up product by handle
    $searchUrl = "$base/products.json?handle=$handle&fields=id,handle,tags"
    try {
        $resp = Invoke-RestMethod -Uri $searchUrl -Headers $headers -Method Get
    } catch {
        Write-Host " -> ERROR fetching: $_" -ForegroundColor Red
        $errorCount++
        continue
    }

    if ($resp.products.Count -eq 0) {
        Write-Host " -> NOT FOUND (skipping)" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    $product = $resp.products[0]
    $productId = $product.id
    $currentTags = $product.tags -split ",\s*" | ForEach-Object { $_.Trim() }

    if ($currentTags -contains $tag) {
        Write-Host " -> already tagged" -ForegroundColor Cyan
        $successCount++
        continue
    }

    # Add the tag
    $newTags = ($currentTags + $tag) -join ", "
    $body = @{ product = @{ id = $productId; tags = $newTags } } | ConvertTo-Json -Depth 3

    try {
        $updateUrl = "$base/products/$productId.json"
        $result = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Put -Body $body
        Write-Host " -> tagged OK (id: $productId)" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host " -> ERROR updating: $_" -ForegroundColor Red
        $errorCount++
    }

    Start-Sleep -Milliseconds 300  # stay under rate limit
}

Write-Host ""
Write-Host "Done. Success/already-tagged: $successCount | Skipped/not-found: $skipCount | Errors: $errorCount"
