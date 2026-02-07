#!/usr/bin/env bash
set -euo pipefail

# Export GitHub workflow secrets by injecting a temporary workflow into repos,
# running it to dump the secrets as an artifact, downloading the artifact,
# and removing the temporary workflow file.

# WARNING: This will commit and run code in each target repository. The
# exported artifacts contain plaintext secrets. DO NOT commit or expose them.

ORG=${1:-Bengo-Hub}
OUTPUT_DIR=${2:-"../../KubeSecrets/git-secrets"}
DRY_RUN=${DRY_RUN:-false}
WORKFLOW_NAME=${WORKFLOW_NAME:-export-secrets-temp.yml}
SKIP_DELETE=${SKIP_DELETE:-false}
# Optional: GitHub PAT and logout behavior
GH_PAT="${3:-${GH_PAT:-}}"  # can be passed as 3rd arg or via env GH_PAT
LOGOUT_AFTER=${LOGOUT_AFTER:-false} # set to true to logout after run
# Org-only mode: export organization-level secrets instead of per-repo secrets
ORG_ONLY=${ORG_ONLY:-false}
# The repository to use when running the temporary workflow that will access org secrets
# Format: <owner>/<repo> (default: <ORG>/devops-k8s)
ORG_TARGET_REPO=${ORG_TARGET_REPO:-"${ORG}/devops-k8s"}

usage(){
  cat <<EOF
Usage: $0 [ORG] [OUTPUT_DIR] [GH_PAT]
Examples:
  # Dry-run: list repos and secrets
  DRY_RUN=true $0 Bengo-Hub ../../KubeSecrets/git-secrets

  # Export org-level secrets (dry-run lists org secret names)
  ORG_ONLY=true DRY_RUN=true $0 Bengo-Hub ../../KubeSecrets/git-secrets

  # Full run with token supplied as 3rd arg (or GH_PAT env)
  $0 Bengo-Hub ../../KubeSecrets/git-secrets <GH_PAT>

Options:
  set DRY_RUN=true to only list repos and secrets without committing
  set ORG_ONLY=true to export org-level secrets using $ORG_TARGET_REPO to run the workflow
  set LOGOUT_AFTER=true to sign out of gh after run (if script logged in)
EOF
}

usage(){
  cat <<EOF
Usage: $0 [ORG] [OUTPUT_DIR]
Example: $0 Bengo-Hub ../../KubeSecrets/git-secrets
Options: set DRY_RUN=true to only list repos and secrets without committing
EOF
}
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage; exit 0; fi

mkdir -p "$OUTPUT_DIR"

auth_check(){
  # Detect gh CLI in PATH or common Windows installation path
  if command -v gh >/dev/null 2>&1; then
    GH_CMD=$(command -v gh)
  elif [ -x "/c/Program Files/GitHub CLI/gh.exe" ]; then
    GH_CMD="/c/Program Files/GitHub CLI/gh.exe"
  elif [ -x "C:/Program Files/GitHub CLI/gh.exe" ]; then
    GH_CMD="C:/Program Files/GitHub CLI/gh.exe"
  else
    echo "gh CLI not found; install it and authenticate"
    exit 1
  fi

  # If a GH_PAT was provided, use it to login non-interactively
  if [[ -n "$GH_PAT" ]]; then
    echo "Using provided GH_PAT to authenticate (temporary)"
    echo "$GH_PAT" | "$GH_CMD" auth login --with-token >/dev/null 2>&1 && LOGGED_IN_BY_SCRIPT=true || { echo "Failed to authenticate with provided token"; exit 1; }
  fi

  # Validate authentication using the detected GH command
  if ! "$GH_CMD" auth status >/dev/null 2>&1; then
    echo "gh not authenticated; run: gh auth login"
    exit 1
  fi
}

# Expose GH command for later use
GH_CMD=${GH_CMD:-gh}

auth_check

echo "Output dir: $(realpath "$OUTPUT_DIR")"

echo "Listing repos for org: $ORG"
if [[ "$ORG_ONLY" == "true" ]]; then
  echo "ORG_ONLY mode enabled: exporting org-level secrets for $ORG"
  # List org secrets
  org_secret_names=$($GH_CMD secret list --org "$ORG" --limit 1000 --json name -q '.[].name' 2>/dev/null || true)
  if [[ -z "$org_secret_names" ]]; then
    echo "No org-level secrets found or insufficient permissions to read org secrets"
    exit 1
  fi
  echo "Org secrets found: $org_secret_names"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run: listing org secrets only; no workflow will be created"
    exit 0
  fi

  # We'll run the workflow once in the target repo
  repoName="$ORG_TARGET_REPO"
  defaultBranch=$( $GH_CMD api "/repos/$repoName" --jq '.default_branch' 2>/dev/null || echo 'main' )
  secret_names="$org_secret_names"
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT
else
  REPOS=$($GH_CMD repo list "$ORG" --limit 1000 --json nameWithOwner,defaultBranch -q '.[] | "'" + .nameWithOwner + "|" + .defaultBranch + "'"')

  if [[ -z "$REPOS" ]]; then
    echo "No repos found or no permission to list repos for org $ORG"
    exit 1
  fi

  # Create a temporary working dir for artifact downloads
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  for entry in $REPOS; do
    repoName=${entry%%|*}
    defaultBranch=${entry##*|}
    echo "Processing repo: $repoName (default branch: $defaultBranch)"

    secret_names=$($GH_CMD secret list --repo "$repoName" --limit 1000 --json name -q '.[].name' 2>/dev/null || true)
    if [[ -z "$secret_names" ]]; then
      echo "  No repo secrets found. Skipping."
      continue
    fi

    echo "  Found secrets: $secret_names"
    if [[ "$DRY_RUN" == "true" ]]; then
      continue
    fi

    # [the rest of the existing loop continues below...]"}]}

  secret_names=$($GH_CMD secret list --repo "$repoName" --limit 1000 --json name -q '.[].name' 2>/dev/null || true)
  if [[ -z "$secret_names" ]]; then
    echo "  No repo secrets found. Skipping."
    continue
  fi

  echo "  Found secrets: $secret_names"
  if [[ "$DRY_RUN" == "true" ]]; then
    continue
  fi

  # Build the workflow content
  workflow_file_content=$(cat <<'YML'
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
          echo "repo: __REPO__" > out/secrets.txt
          echo "branch: $GITHUB_REF" >> out/secrets.txt
__SECRET_ECHOES__
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: secrets
          path: out/secrets.txt
YML
)

  # Build secret echoes block
  secret_echoes=""
  # secret_names may be multiple lines; iterate
  while read -r s; do
    [[ -z "$s" ]] && continue
    safe=$(echo "$s" | tr -d '"')
    secret_echoes+="          echo '---' >> out/secrets.txt\n"
    secret_echoes+="          echo 'secret: $safe' >> out/secrets.txt\n"
    # Use single quotes inside run to preserve literal ${{ secrets.NAME }} for GitHub
    secret_echoes+="          echo 'value: ${{ secrets.$safe }}' >> out/secrets.txt\n"
  done <<< "$secret_names"

  workflow_content=$(echo "$workflow_file_content" | sed "s/__REPO__/$repoName/" | sed "s#__SECRET_ECHOES__#$secret_echoes#")

  # Create workflow via GitHub API (PUT contents)
  path=".github/workflows/$WORKFLOW_NAME"
  echo "  Creating workflow $path in $repoName"
  encoded=$(echo -n "$workflow_content" | base64 -w0)
  create_resp=$(gh api --method PUT "/repos/$repoName/contents/$path" -f message="ci: add temporary export workflow" -f content="$encoded" 2>&1) || true
  if [[ $? -ne 0 ]]; then
    echo "  Failed to create workflow in $repoName: $create_resp"
    continue
  fi

  echo "  Triggering workflow run"
  "$GH_CMD" workflow run "$WORKFLOW_NAME" --repo "$repoName" --ref "$defaultBranch" || true

  # Poll for run completion
  runId=""
  for i in {1..120}; do
    sleep 5
    runId=$(gh run list --repo "$repoName" --workflow "$WORKFLOW_NAME" --limit 1 --json databaseId,status -q '.[0].databaseId' 2>/dev/null || true)
    status=$(gh run list --repo "$repoName" --workflow "$WORKFLOW_NAME" --limit 1 --json databaseId,status -q '.[0].status' 2>/dev/null || true)
    conclusion=$(gh run list --repo "$repoName" --workflow "$WORKFLOW_NAME" --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || true)
    if [[ -n "$runId" && "$status" == "completed" ]]; then
      echo "    Run $runId completed (conclusion: $conclusion)"
      break
    fi
  done

  if [[ -z "$runId" ]]; then
    echo "  Run not found or timed out for $repoName"
  else
    dest="$OUTPUT_DIR/$(echo "$repoName" | sed 's|/|__|g')"
    mkdir -p "$dest"
    echo "  Downloading artifacts to $dest"
    "$GH_CMD" run download "$runId" --repo "$repoName" --name secrets -D "$dest" || echo "  Warning: failed to download artifact for $repoName"
  fi

  # Remove workflow file
  if [[ "$SKIP_DELETE" != "true" ]]; then
    echo "  Removing temporary workflow from $repoName"
    sha=$($GH_CMD api "/repos/$repoName/contents/$path" --jq '.sha' 2>/dev/null || true)
    if [[ -n "$sha" ]]; then
      $GH_CMD api --method DELETE "/repos/$repoName/contents/$path" -f message="ci: remove temporary export workflow" -f sha="$sha" || echo "  Warning: failed to delete workflow in $repoName"
    else
      echo "  Could not locate workflow file sha for $repoName"
    fi
  else
    echo "  Skipping delete of workflow file (SKIP_DELETE set)"
  fi

  # If script logged in using GH_PAT and user requested logout, sign out
  if [[ "$LOGGED_IN_BY_SCRIPT" == "true" && "$LOGOUT_AFTER" == "true" ]]; then
    echo "Signing out gh (logout) as requested"
    $GH_CMD auth logout -h github.com -y || true
  fi

  echo "  Completed processing $repoName"
  echo ""

done <<< "$REPOS"

echo "All done. Artifacts saved to: $(realpath "$OUTPUT_DIR")"

echo "IMPORTANT: Artifacts contain plaintext secrets. Secure or delete immediately." >&2
