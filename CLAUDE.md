# Project Memory

## Shopify CLI

- Preferred Shopify CLI command path on this machine: `C:\Users\millc\AppData\Roaming\npm\shopify.ps1`
- If PowerShell script execution is blocked in automation, use the Windows launcher instead: `C:\Users\millc\AppData\Roaming\npm\shopify.cmd`
- Verified Shopify CLI version on April 21, 2026: `3.93.2`

## Workflow Preferences

- Use Shopify CLI for theme sync work with the store.
- Use `shopify theme pull` to pull remote theme changes into the local project.
- Use `shopify theme push` or other Shopify CLI theme commands to send theme changes back to Shopify.
- Do not use GitHub or Git remotes as the source of truth for theme sync unless the user explicitly asks.

## Git Usage

- Use Git locally for version history, checkpoints, diffs, rollback, and branches/forks as a safety net.
- Do not use Git for online syncing by default.
- Do not push to GitHub or rely on Git remotes unless the user explicitly asks.
