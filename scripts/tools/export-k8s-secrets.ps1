# Export Kubernetes Secrets to Plain Text YAML Files
# WARNING: This exports sensitive data - use with extreme caution!
# The exported files should NEVER be committed to version control

param(
    [string]$Namespace = "",
    [string]$OutputDir = "KubeSecrets",
    [switch]$AllNamespaces
)

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Kubernetes Secrets Export Tool" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Warning "This tool exports secrets in PLAIN TEXT!"
Write-Warning "Exported files contain sensitive data and should NEVER be committed to git."
Write-Host ""

# Confirm before proceeding
$confirm = Read-Host "Continue? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Export cancelled." -ForegroundColor Yellow
    exit 0
}

# Create output directory
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$FullOutputPath = Join-Path $RepoRoot $OutputDir

if (Test-Path $FullOutputPath) {
    Write-Warning "Output directory already exists: $FullOutputPath"
    $overwrite = Read-Host "Overwrite existing files? (yes/no)"
    if ($overwrite -ne "yes") {
        Write-Host "Export cancelled." -ForegroundColor Yellow
        exit 0
    }
} else {
    New-Item -ItemType Directory -Path $FullOutputPath -Force | Out-Null
}

# Create .gitignore to prevent accidental commits
$gitignorePath = Join-Path $FullOutputPath ".gitignore"
@"
# Prevent accidental commit of secrets
*.yml
*.yaml
*.json
*.txt
!.gitignore
"@ | Set-Content $gitignorePath

Write-Host "Created .gitignore in $FullOutputPath" -ForegroundColor Green

# Build kubectl command
if ($AllNamespaces) {
    Write-Host "Exporting secrets from ALL namespaces..." -ForegroundColor Yellow
    $namespaceFlag = "--all-namespaces"
} elseif ($Namespace) {
    Write-Host "Exporting secrets from namespace: $Namespace" -ForegroundColor Yellow
    $namespaceFlag = "-n $Namespace"
} else {
    Write-Host "Exporting secrets from current/default namespace..." -ForegroundColor Yellow
    $namespaceFlag = ""
}

# Get all secrets
Write-Host "Fetching secrets list..." -ForegroundColor Cyan
$secretsJson = kubectl get secrets $namespaceFlag -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to fetch secrets from Kubernetes cluster"
    Write-Host "Error: $secretsJson" -ForegroundColor Red
    exit 1
}

$secrets = $secretsJson | ConvertFrom-Json

if ($secrets.items.Count -eq 0) {
    Write-Warning "No secrets found!"
    exit 0
}

Write-Host "Found $($secrets.items.Count) secret(s)" -ForegroundColor Green
Write-Host ""

# Export each secret
$exportCount = 0
foreach ($secret in $secrets.items) {
    $secretName = $secret.metadata.name
    $secretNamespace = $secret.metadata.namespace
    
    # Skip service account tokens (usually auto-generated)
    if ($secret.type -eq "kubernetes.io/service-account-token") {
        Write-Host "  Skipping service account token: $secretName" -ForegroundColor DarkGray
        continue
    }

    Write-Host "Exporting: $secretName (namespace: $secretNamespace)" -ForegroundColor Cyan

    # Create namespace directory if needed
    $nsDir = Join-Path $FullOutputPath $secretNamespace
    if (-not (Test-Path $nsDir)) {
        New-Item -ItemType Directory -Path $nsDir -Force | Out-Null
    }

    # Decode base64 data
    $decodedData = @{}
    if ($secret.data) {
        foreach ($key in $secret.data.PSObject.Properties.Name) {
            $base64Value = $secret.data.$key
            try {
                $bytes = [System.Convert]::FromBase64String($base64Value)
                $decodedValue = [System.Text.Encoding]::UTF8.GetString($bytes)
                $decodedData[$key] = $decodedValue
            } catch {
                Write-Warning "    Failed to decode key: $key"
                $decodedData[$key] = "<DECODE_ERROR>"
            }
        }
    }

    # Create YAML output
    $yaml = @"
# Kubernetes Secret: $secretName
# Namespace: $secretNamespace
# Type: $($secret.type)
# Exported: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# WARNING: This file contains PLAIN TEXT secrets!

apiVersion: v1
kind: Secret
metadata:
  name: $secretName
  namespace: $secretNamespace
type: $($secret.type)
stringData:
"@

    foreach ($key in $decodedData.Keys) {
        $value = $decodedData[$key]
        # Escape special characters and indent properly
        $escapedValue = $value -replace '"', '\"'
        $yaml += "`n  $key: |"
        # Multi-line string handling
        foreach ($line in $value -split "`n") {
            $yaml += "`n    $line"
        }
    }

    # Save to file
    $filename = "$secretName.yml"
    $filepath = Join-Path $nsDir $filename
    $yaml | Set-Content $filepath -Encoding UTF8

    Write-Host "  ✓ Exported to: $filepath" -ForegroundColor Green
    $exportCount++
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Export Complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Exported $exportCount secret(s) to: $FullOutputPath" -ForegroundColor Green
Write-Host ""
Write-Warning "SECURITY REMINDER:"
Write-Host "  - These files contain PLAIN TEXT secrets"
Write-Host "  - DO NOT commit to version control"
Write-Host "  - Secure these files with proper file permissions"
Write-Host "  - Delete after use if no longer needed"
Write-Host ""

# Create a README in the output directory
$readmePath = Join-Path $FullOutputPath "README.md"
@"
# Kubernetes Secrets Export

**⚠️ WARNING: This directory contains PLAIN TEXT secrets!**

## Security Guidelines

1. **NEVER commit these files to version control**
2. **Secure with proper file permissions**
3. **Delete after use if no longer needed**
4. **Share only through secure channels**

## Files

Exported on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Total secrets: $exportCount

Each file is organized by namespace and contains decoded secret values.

## Re-importing Secrets

To re-import a secret into Kubernetes:

``````powershell
kubectl apply -f ./namespace/secret-name.yml
``````

Or using bash:

``````bash
kubectl apply -f ./namespace/secret-name.yml
``````

## Cleanup

To remove all exported files:

``````powershell
Remove-Item -Recurse -Force ./KubeSecrets
``````
"@ | Set-Content $readmePath

Write-Host "Created README.md with security guidelines" -ForegroundColor Green
