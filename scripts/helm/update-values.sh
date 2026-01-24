#!/usr/bin/env bash
# =============================================================================
# Centralized Helm Values Update Script
# =============================================================================
# Purpose: Standardized, reusable script for updating image tags in devops-k8s
# Reduces code duplication across all build.sh scripts
#
# Usage:
#   source ~/devops-k8s/scripts/helm/update-values.sh
#   update_helm_values "ordering-backend" "fb45a308" "docker.io/codevertex/ordering-backend"
#
# Or directly:
#   ~/devops-k8s/scripts/helm/update-values.sh \
#     --app ordering-backend \
#     --tag fb45a308 \
#     --repo docker.io/codevertex/ordering-backend
#
# Environment Variables (optional, uses defaults if not set):
#   DEVOPS_REPO      - GitHub repo (default: Bengo-Hub/devops-k8s)
#   DEVOPS_DIR       - Local directory (default: $HOME/devops-k8s)
#   GIT_EMAIL        - Commit email (default: dev@bengobox.com)
#   GIT_USER         - Commit user (default: BengoBox Bot)
#   TOKEN            - GitHub token (GH_PAT, GIT_TOKEN, GIT_SECRET)
# =============================================================================

set -euo pipefail

# Source this script to use functions, or run directly for CLI mode
SCRIPT_MODE="${SCRIPT_MODE:-cli}"

# =============================================================================
# LOGGING
# =============================================================================
log_info()    { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
log_step()    { echo -e "\033[0;35m[STEP]\033[0m $1"; }

# =============================================================================
# CONFIGURATION
# =============================================================================
# Resolve token from available sources (priority order)
# Note: This function ONLY echoes the token, no log output
resolve_token() {
    local token=""
    if [[ -n "${GH_PAT:-}" ]]; then
        token="$GH_PAT"
    elif [[ -n "${GIT_TOKEN:-}" ]]; then
        token="$GIT_TOKEN"
    elif [[ -n "${GIT_SECRET:-}" ]]; then
        token="$GIT_SECRET"
    fi
    echo "$token"
}

# Validate cross-repo push permissions
validate_cross_repo_push() {
    local origin_repo="${GITHUB_REPOSITORY:-}"
    local target_repo="$1"
    local token="$2"
    
    # If not in CI/CD or pushing to same repo, validation not needed
    if [[ -z "$origin_repo" || "$target_repo" == "$origin_repo" ]]; then
        return 0
    fi
    
    # Cross-repo push requires GH_PAT or GIT_SECRET
    if [[ -z "${GH_PAT:-${GIT_SECRET:-}}" ]]; then
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "CRITICAL: GH_PAT or GIT_SECRET required for cross-repo push"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "You are pushing from: ${origin_repo}"
        log_error "         to repository: ${target_repo}"
        log_error ""
        log_error "Default GITHUB_TOKEN does NOT have cross-repo write access."
        log_error "Deploy keys also do NOT work for pushing to other repos."
        log_error ""
        log_error "ACTION REQUIRED:"
        log_error "1. Create a Personal Access Token (PAT) at:"
        log_error "   https://github.com/settings/tokens/new"
        log_error "2. Select scope: 'repo' (full control)"
        log_error "3. Add as repository secret named 'GH_PAT' or 'GIT_SECRET'"
        log_error "4. Re-run this workflow"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    return 0
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================
update_helm_values() {
    local app_name="${1:-}"
    local image_tag="${2:-}"
    local image_repo="${3:-}"
    
    # Validate required arguments
    if [[ -z "$app_name" || -z "$image_tag" ]]; then
        log_error "Usage: update_helm_values <app-name> <image-tag> [image-repo]"
        log_error "  app_name   : Name of application (e.g., ordering-backend)"
        log_error "  image_tag  : Image tag to deploy (e.g., fb45a308)"
        log_error "  image_repo : Full image repo (optional, e.g., docker.io/codevertex/ordering-backend)"
        return 1
    fi
    
    # Set defaults
    local devops_repo="${DEVOPS_REPO:-Bengo-Hub/devops-k8s}"
    local devops_dir="${DEVOPS_DIR:-$HOME/devops-k8s}"
    local values_file="apps/${app_name}/values.yaml"
    local git_email="${GIT_EMAIL:-dev@bengobox.com}"
    local git_user="${GIT_USER:-BengoBox Bot}"
    
    # Resolve token
    local token
    token=$(resolve_token)
    
    # Log which token source was used
    if [[ -n "$token" ]]; then
        if [[ "$token" == "${GH_PAT:-}" ]]; then
            log_info "Using GH_PAT for git operations"
        elif [[ "$token" == "${GIT_TOKEN:-}" ]]; then
            log_info "Using GIT_TOKEN for git operations"
        elif [[ "$token" == "${GIT_SECRET:-}" ]]; then
            log_info "Using GIT_SECRET for git operations"
        fi
    else
        log_warning "No GitHub token found"
    fi
    if ! validate_cross_repo_push "$devops_repo" "$token"; then
        return 1
    fi
    
    log_step "Updating Helm Values"
    log_info "App: $app_name"
    log_info "Tag: $image_tag"
    [[ -n "$image_repo" ]] && log_info "Repo: $image_repo"
    log_info "DevOps Dir: $devops_dir"
    log_info ""
    
    # Build clone URL
    local clone_url="https://github.com/${devops_repo}.git"
    [[ -n "$token" ]] && clone_url="https://x-access-token:${token}@github.com/${devops_repo}.git"
    
    # Clone or update devops-k8s repo
    if [[ ! -d "$devops_dir" ]]; then
        log_step "Cloning devops-k8s repository..."
        git clone "$clone_url" "$devops_dir" 2>&1 | grep -v "Cloning into\|Resolving deltas" || {
            log_error "Failed to clone devops-k8s"
            return 1
        }
        log_success "Repository cloned"
    fi
    
    # Change to devops directory
    pushd "$devops_dir" >/dev/null || return 1
    
    # Configure git
    log_step "Configuring git..."
    git config user.email "$git_email"
    git config user.name "$git_user"
    log_success "Git configured"
    
    # Ensure we have latest changes
    log_step "Fetching latest from origin/main..."
    git fetch origin main >/dev/null 2>&1 || true
    git checkout main >/dev/null 2>&1 || git checkout -b main >/dev/null 2>&1 || true
    git reset --hard origin/main >/dev/null 2>&1 || true
    log_success "Branch synchronized"
    
    # Check if values file exists
    if [[ ! -f "$values_file" ]]; then
        log_error "Values file not found: $values_file"
        popd >/dev/null || true
        return 1
    fi
    
    # Update image tag (and optionally repo) using yq
    log_step "Updating $values_file..."
    if [[ -n "$image_repo" ]]; then
        # Update both repository and tag
        IMAGE_REPO_ENV="$image_repo" IMAGE_TAG_ENV="$image_tag" \
            yq e -i '.image.repository = strenv(IMAGE_REPO_ENV) | .image.tag = strenv(IMAGE_TAG_ENV)' "$values_file"
    else
        # Update tag only
        IMAGE_TAG_ENV="$image_tag" \
            yq e -i '.image.tag = strenv(IMAGE_TAG_ENV)' "$values_file"
    fi
    
    # Verify the update
    local updated_tag
    updated_tag=$(yq e '.image.tag' "$values_file")
    if [[ "$updated_tag" != "$image_tag" ]]; then
        log_error "Failed to update image tag. Expected: $image_tag, Got: $updated_tag"
        popd >/dev/null || true
        return 1
    fi
    log_success "Image tag updated: $updated_tag"
    
    # Commit changes
    log_step "Committing changes..."
    git add "$values_file"
    if git diff --cached --quiet; then
        log_warning "No changes to commit (tag already $image_tag)"
        popd >/dev/null || true
        return 0
    fi
    
    local commit_msg="${app_name}:${image_tag} released"
    git commit -m "$commit_msg" >/dev/null 2>&1 || {
        log_warning "Commit failed (changes may already be committed)"
    }
    log_success "Changes committed: $commit_msg"
    
    # Push changes
    if [[ -z "$token" ]]; then
        log_error "No GitHub token (GH_PAT/GIT_TOKEN/GIT_SECRET) available for devops-k8s push"
        log_warning "Skipping git push; set GH_PAT or GIT_TOKEN (preferred) with repo write perms to Bengo-Hub/devops-k8s"
        popd >/dev/null || true
        return 0
    fi
    
    log_step "Pushing changes to origin/main..."
    # Update remote URL to include token for authentication
    local push_url="https://x-access-token:${token}@github.com/${devops_repo}.git"
    git remote set-url origin "$push_url" >/dev/null 2>&1 || {
        log_warning "Failed to update remote URL, attempting direct push"
    }
    
    if git push origin HEAD:main 2>&1 | grep -q "Everything up-to-date\|main -> main"; then
        log_success "Changes pushed to origin/main"
    else
        log_error "Failed to push changes - check token permissions"
        log_error "Remote URL: $(git remote get-url origin 2>/dev/null | sed 's/:[^@]*@/:***@/')"
        popd >/dev/null || true
        return 1
    fi
    
    popd >/dev/null || true
    
    log_step "========================================="
    log_success "Helm values updated successfully!"
    log_step "========================================="
    return 0
}

# =============================================================================
# CLI MODE (direct execution)
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    app_name=""
    image_tag=""
    image_repo=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                app_name="$2"
                shift 2
                ;;
            --tag)
                image_tag="$2"
                shift 2
                ;;
            --repo)
                image_repo="$2"
                shift 2
                ;;
            --devops-dir)
                DEVOPS_DIR="$2"
                shift 2
                ;;
            --devops-repo)
                DEVOPS_REPO="$2"
                shift 2
                ;;
            -h|--help)
                cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --app NAME          Application name (required, e.g., ordering-backend)
  --tag TAG           Image tag to deploy (required, e.g., fb45a308)
  --repo REPO         Full image repository (optional, e.g., docker.io/codevertex/app)
  --devops-dir DIR    DevOps repo directory (default: \$HOME/devops-k8s)
  --devops-repo REPO  DevOps repo (default: Bengo-Hub/devops-k8s)
  -h, --help          Show this help message

Environment Variables:
  GH_PAT              GitHub Personal Access Token (preferred for cross-repo access)
  GIT_TOKEN           GitHub Actions default token (use in GitHub workflows)
  GIT_SECRET          Custom GitHub token secret (set in GitHub Actions secrets)
  GIT_EMAIL           Git commit email (default: dev@bengobox.com)
  GIT_USER            Git commit user (default: BengoBox Bot)

Examples:
  # Update only tag
  $(basename "$0") --app ordering-backend --tag fb45a308

  # Update repo and tag
  $(basename "$0") --app ordering-backend --tag fb45a308 --repo docker.io/codevertex/ordering-backend

  # With custom devops directory
  DEVOPS_DIR=/custom/path $(basename "$0") --app ordering-backend --tag fb45a308
EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Validate arguments
    if [[ -z "$app_name" || -z "$image_tag" ]]; then
        log_error "Missing required arguments"
        echo ""
        "$(basename "$0")" --help
        exit 1
    fi
    
    # Execute the update
    update_helm_values "$app_name" "$image_tag" "$image_repo"
    exit $?
fi
