param(
  [string]$Org = "Bengo-Hub",
  [string]$OutputDir = "..\..\KubeSecrets\git-secrets",
  [switch]$DryRun,
  [string]$WorkflowName = "export-secrets-temp.yml",
  [switch]$SkipDelete,
  [string]$GH_PAT = "",
  [switch]$LogoutAfter,
  [switch]$OrgOnly,
  [string]$OrgTargetRepo = ""
)

function Log-Info { Write-Host "[INFO]" $args -ForegroundColor Cyan }
function Log-Warn { Write-Host "[WARN]" $args -ForegroundColor Yellow }
function Log-Error { Write-Host "[ERROR]" $args -ForegroundColor Red }

# Pre-flight checks
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Log-Error "gh CLI not found. Install GitHub CLI and authenticate (gh auth login)."
  exit 1
}

# If GH_PAT was provided, use it to login non-interactively (safer piping method)
$LoggedInByScript = $false
if ($GH_PAT -and $GH_PAT.Trim() -ne "") {
    Log-Info "Authenticating using provided GH_PAT (temporary)"
    try {
        # Pipe the token into gh auth login --with-token
        $procOutput = $GH_PAT | gh auth login --with-token 2>&1
        if ($LASTEXITCODE -eq 0) {
            $LoggedInByScript = $true
            Log-Info "Authenticated via provided GH_PAT"
        } else {
            Log-Warn "gh login returned non-zero exit code. Output: $procOutput"
        }
    } catch {
        Log-Warn "Failed to authenticate with provided GH_PAT: $_"
    }
}

# Verify authentication
if (-not ($null -ne (gh auth status 2>$null))) {
  Log-Error "gh not authenticated. Run: gh auth login"
  exit 1
}

# Quick permission check: confirm we can list at least one repo in the org
$testRepo = gh repo list $Org --limit 1 --json nameWithOwner -q '.[].nameWithOwner' 2>$null
if (-not $testRepo) {
    Log-Error "Unable to list repositories in org '$Org'. Your token may lack required scopes (repo, workflow) or you lack org access."
    Log-Error "Required scopes: 'repo' (full), 'workflow' (actions), and org membership with appropriate permissions."
    Log-Error "If using a personal access token (PAT), create one at: https://github.com/settings/tokens (select 'repo' and 'workflow' scopes)."
    if ($LoggedInByScript) {
        Log-Info "Logging out due to failed permission check"
        gh auth logout -h github.com -y
    }
    exit 1
}

# Ensure output dir
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$absOutput = Resolve-Path $OutputDir
Log-Info "Output directory: $absOutput"

# List repos
Log-Info "Listing repositories for org: $Org"
$useOrgSecrets = $false
if ($OrgOnly) {
    if (-not $OrgTargetRepo -or $OrgTargetRepo.Trim() -eq '') { $OrgTargetRepo = "$Org/devops-k8s" }
    Log-Info "ORG_ONLY mode enabled. Will use repo: $OrgTargetRepo to run the temporary workflow and export org-level secrets for $Org"

    # List org-level secrets
    $orgSecretNamesRaw = gh secret list -o $Org --json name -q '.[].name' 2>&1 | Out-String
    if ($orgSecretNamesRaw.Trim() -eq '') { Log-Error "No org-level secrets found or insufficient permissions to list org secrets for: $Org"; exit 1 }
    $orgSecretNames = $orgSecretNamesRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    Log-Info "Found org secrets: $($orgSecretNames -join ', ')"

    if ($DryRun) { Log-Info "Dry run: would export org secrets above and run workflow in repo: $OrgTargetRepo"; exit 0 }

    $repoNames = @($OrgTargetRepo)
    $useOrgSecrets = $true
} else {
    # Capture raw repo list output for debugging
    $repoNamesRaw = gh repo list $Org --limit 1000 --json nameWithOwner -q '.[].nameWithOwner' 2>&1 | Out-String
    Log-Info "Raw repo list output length: $($repoNamesRaw.Length)"
    if ($repoNamesRaw.Trim() -eq '') {
        Log-Warn "gh repo list returned no output. Raw output below for debugging:" 
        Write-Host $repoNamesRaw
    }
    $repoNames = $repoNamesRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if (-not $repoNames -or $repoNames.Count -eq 0) { Log-Error "No repos found or insufficient permissions"; exit 1 }
}

foreach ($repoName in $repoNames) {
  # Resolve default branch for repo
  $defaultBranch = (gh api "/repos/$repoName" --jq '.default_branch' 2>$null) -as [string]
  if (-not $defaultBranch) { $defaultBranch = 'main' }
  Log-Info "Processing repo: $repoName (default: $defaultBranch)"

  if ($useOrgSecrets) {
    $secretNames = $orgSecretNames
    Log-Info "  Using org-level secrets: $($secretNames -join ', ')"
  } else {
    $secretNamesRaw = gh secret list --repo $repoName --limit 1000 --json name -q '.[] | .name' 2>$null | Out-String
    if (-not $secretNamesRaw.Trim()) { Log-Info "  No repo secrets found. Skipping."; continue }

    $secretNames = $secretNamesRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    Log-Info "  Found secrets: $($secretNames -join ', ')"
    if ($DryRun) { continue }
  }

  # Build workflow content
  $secretEchoes = ""
  foreach ($s in $secretNames) {
    $safe = $s -replace '"',''
    $secretEchoes += "          echo '---' >> out/secrets.txt`n"
    $secretEchoes += "          echo 'secret: $safe' >> out/secrets.txt`n"
    $secretEchoes += "          echo 'value: `$" + "{{ secrets." + $safe + " }}' >> out/secrets.txt`n"
  }

  $workflow = @"
name: Temporary Export Secrets
on:
  workflow_dispatch: {}
permissions:
  contents: read
jobs:
  export_secrets:
    runs-on: ubuntu-latest
    steps:
      - name: Create output dir
        run: mkdir -p out
      - name: Write secrets file
        run: |
          echo "repo: $repoName" > out/secrets.txt
          echo "branch: $env:GITHUB_REF" >> out/secrets.txt
$secretEchoes
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: secrets
          path: out/secrets.txt
"@

  # Create workflow file via GitHub API
  $path = ".github/workflows/$WorkflowName"
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($workflow))
  $create = gh api --method PUT "/repos/$repoName/contents/$path" -f message="ci: add temporary export workflow" -f content="$b64" 2>&1
  if ($LASTEXITCODE -ne 0) { Log-Warn "  Failed to create workflow: $create"; continue }

  Log-Info "  Workflow created. Triggering run"
  gh workflow run $WorkflowName --repo $repoName --ref $defaultBranch

  # Wait for run completion
  $attempts = 0; $runId = $null
  while ($attempts -lt 120) {
    Start-Sleep -Seconds 5; $attempts++
    $run = gh run list --repo $repoName --workflow $WorkflowName --limit 1 --json databaseId,status,conclusion -q '.[0]' 2>$null
    if ($run) { $j = $run | ConvertFrom-Json; $runId = $j.databaseId; $status = $j.status; $conclusion = $j.conclusion; Log-Info "    Run $runId status: $status conclusion: $conclusion"; if ($status -eq 'completed') { break } }
  }
  if (-not $runId) { Log-Warn "  Run not found or timed out" } else { $dest = Join-Path $absOutput ($repoName -replace '/','__'); if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }; gh run download $runId --repo $repoName --name secrets -D $dest }

  # Delete workflow
  if (-not $SkipDelete) {
    $info = gh api "/repos/$repoName/contents/$path" 2>$null | ConvertFrom-Json
    if ($info -and $info.sha) { gh api --method DELETE "/repos/$repoName/contents/$path" -f message="ci: remove temporary export workflow" -f sha=$info.sha 2>&1 }
  }

  Log-Info "  Completed $repoName"
}

# Logout if we logged in and user requested logout
if ($LoggedInByScript -and $LogoutAfter) {
  Log-Info "Logging out from gh (cleanup)"
  gh auth logout -h github.com -y
}

Log-Info "All done. Artifacts in: $absOutput"
Write-Host "SECURITY: Artifacts contain plaintext secrets. Secure or delete immediately." -ForegroundColor Red

Log-Info "All done. Artifacts in: $absOutput"
Write-Host "SECURITY: Artifacts contain plaintext secrets. Secure or delete immediately." -ForegroundColor Red
