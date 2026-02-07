#!/usr/bin/env pwsh
# Temporary script to test secret propagation from PowerShell

$secretsFile = "D:/KubeSecrets/git-secrets/Bengo-Hub__devops-k8s/secrets.txt"
$targetRepo = "Bengo-Hub/isp-billing-backend"
$secretsToPropagate = @("REGISTRY_USERNAME", "REGISTRY_PASSWORD")

Write-Host "[INFO] Reading secrets from: $secretsFile"
$content = Get-Content $secretsFile -Raw

# Parse secrets
$secretsMap = @{}
$blocks = $content -split '---'

foreach ($block in $blocks) {
    if ($block -match 'secret:\s*(.+?)\s*\n' -and $matches[1]) {
        $secretName = $matches[1].Trim()
        if ($block -match 'value:\s*(.*)' -and $matches[1]) {
            $value = $matches[1]
            # Handle multi-line values
            $lines = $block -split "`n"
            $valueStarted = $false
            $valueLines = @()
            foreach ($line in $lines) {
                if ($line -match '^value:\s*(.*)') {
                    $valueStarted = $true
                    $valueLines += $matches[1]
                } elseif ($valueStarted -and $line -notmatch '^(secret:|---|\s*$)') {
                    $valueLines += $line
                }
            }
            $value = ($valueLines -join "`n").TrimEnd()
            $secretsMap[$secretName] = $value
        }
    }
}

Write-Host "[INFO] Parsed $($secretsMap.Count) secrets"
Write-Host "[INFO] Propagating to: $targetRepo"

foreach ($secretName in $secretsToPropagate) {
    if (-not $secretsMap.ContainsKey($secretName)) {
        Write-Host "[WARN] $secretName not found in secrets file"
        continue
    }
    
    $value = $secretsMap[$secretName]
    
    # Debug output
    if ($secretName -eq "REGISTRY_USERNAME") {
        Write-Host "[DEBUG] Username: $value"
    } elseif ($secretName -like "*PASSWORD*") {
        $masked = "$($value[0])****$($value[-1])"
        Write-Host "[DEBUG] Password length: $($value.Length) chars, masked: $masked"
    }
    
    # Set secret (plain text, GitHub encrypts it)
    Write-Host "[INFO] Setting $secretName in $targetRepo"
    $value | gh secret set $secretName --repo $targetRepo --body -
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[SUCCESS] Set $secretName"
    } else {
        Write-Host "[ERROR] Failed to set $secretName"
    }
}
