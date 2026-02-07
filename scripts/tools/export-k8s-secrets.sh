#!/bin/bash

# Export Kubernetes Secrets to Plain Text YAML Files
# WARNING: This exports sensitive data - use with extreme caution!
# The exported files should NEVER be committed to version control

set -e

# Default values
NAMESPACE=""
OUTPUT_DIR="KubeSecrets"
ALL_NAMESPACES=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -A|--all-namespaces)
            ALL_NAMESPACES=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Export Kubernetes secrets to plain text YAML files"
            echo ""
            echo "Options:"
            echo "  -n, --namespace <name>    Export secrets from specific namespace"
            echo "  -o, --output <dir>        Output directory (default: KubeSecrets)"
            echo "  -A, --all-namespaces      Export from all namespaces"
            echo "  -h, --help                Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Export from default namespace"
            echo "  $0 -n production                      # Export from production namespace"
            echo "  $0 -A                                 # Export from all namespaces"
            echo "  $0 -n staging -o ./staging-secrets   # Custom output directory"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}Kubernetes Secrets Export Tool${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""
echo -e "${YELLOW}⚠️  WARNING: This tool exports secrets in PLAIN TEXT!${NC}"
echo -e "${YELLOW}⚠️  Exported files contain sensitive data and should NEVER be committed to git.${NC}"
echo ""

# Confirm before proceeding
read -p "Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Export cancelled.${NC}"
    exit 0
fi

# Get repository root (2 levels up from scripts/tools)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FULL_OUTPUT_PATH="$REPO_ROOT/$OUTPUT_DIR"

# Create output directory
if [ -d "$FULL_OUTPUT_PATH" ]; then
    echo -e "${YELLOW}Output directory already exists: $FULL_OUTPUT_PATH${NC}"
    read -p "Overwrite existing files? (yes/no): " overwrite
    if [ "$overwrite" != "yes" ]; then
        echo -e "${YELLOW}Export cancelled.${NC}"
        exit 0
    fi
else
    mkdir -p "$FULL_OUTPUT_PATH"
fi

# Create .gitignore
cat > "$FULL_OUTPUT_PATH/.gitignore" << 'EOF'
# Prevent accidental commit of secrets
*.yml
*.yaml
*.json
*.txt
!.gitignore
EOF

echo -e "${GREEN}Created .gitignore in $FULL_OUTPUT_PATH${NC}"

# Build kubectl command
if [ "$ALL_NAMESPACES" = true ]; then
    echo -e "${YELLOW}Exporting secrets from ALL namespaces...${NC}"
    NAMESPACE_FLAG="--all-namespaces"
    NAMESPACE_PARAM=""
elif [ -n "$NAMESPACE" ]; then
    echo -e "${YELLOW}Exporting secrets from namespace: $NAMESPACE${NC}"
    NAMESPACE_FLAG="-n $NAMESPACE"
    NAMESPACE_PARAM="-n $NAMESPACE"
else
    echo -e "${YELLOW}Exporting secrets from current/default namespace...${NC}"
    NAMESPACE_FLAG=""
    NAMESPACE_PARAM=""
fi

# Get all secrets
echo -e "${CYAN}Fetching secrets list...${NC}"
SECRETS_JSON=$(kubectl get secrets $NAMESPACE_FLAG -o json 2>&1)

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to fetch secrets from Kubernetes cluster${NC}"
    echo "$SECRETS_JSON"
    exit 1
fi

# Count secrets (excluding service account tokens)
SECRET_COUNT=$(echo "$SECRETS_JSON" | jq -r '.items[] | select(.type != "kubernetes.io/service-account-token") | .metadata.name' | wc -l)

if [ "$SECRET_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No secrets found!${NC}"
    exit 0
fi

echo -e "${GREEN}Found $SECRET_COUNT secret(s)${NC}"
echo ""

# Export each secret
EXPORT_COUNT=0

echo "$SECRETS_JSON" | jq -c '.items[]' | while read -r secret; do
    SECRET_NAME=$(echo "$secret" | jq -r '.metadata.name')
    SECRET_NAMESPACE=$(echo "$secret" | jq -r '.metadata.namespace')
    SECRET_TYPE=$(echo "$secret" | jq -r '.type')
    
    # Skip service account tokens
    if [ "$SECRET_TYPE" = "kubernetes.io/service-account-token" ]; then
        echo -e "  ${CYAN}Skipping service account token: $SECRET_NAME${NC}"
        continue
    fi
    
    echo -e "${CYAN}Exporting: $SECRET_NAME (namespace: $SECRET_NAMESPACE)${NC}"
    
    # Create namespace directory
    NS_DIR="$FULL_OUTPUT_PATH/$SECRET_NAMESPACE"
    mkdir -p "$NS_DIR"
    
    # Get secret with decoded data
    kubectl get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" -o json | \
    jq -r '
        "# Kubernetes Secret: " + .metadata.name,
        "# Namespace: " + .metadata.namespace,
        "# Type: " + .type,
        "# Exported: " + (now | strftime("%Y-%m-%d %H:%M:%S")),
        "# WARNING: This file contains PLAIN TEXT secrets!",
        "",
        "apiVersion: v1",
        "kind: Secret",
        "metadata:",
        "  name: " + .metadata.name,
        "  namespace: " + .metadata.namespace,
        "type: " + .type,
        "stringData:",
        (
            .data // {} | 
            to_entries[] | 
            "  " + .key + ": |",
            "    " + (.value | @base64d | split("\n") | join("\n    "))
        )
    ' > "$NS_DIR/$SECRET_NAME.yml"
    
    echo -e "  ${GREEN}✓ Exported to: $NS_DIR/$SECRET_NAME.yml${NC}"
    ((EXPORT_COUNT++))
done

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${GREEN}Export Complete!${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "${GREEN}Exported secrets to: $FULL_OUTPUT_PATH${NC}"
echo ""
echo -e "${YELLOW}SECURITY REMINDER:${NC}"
echo "  - These files contain PLAIN TEXT secrets"
echo "  - DO NOT commit to version control"
echo "  - Secure these files with proper file permissions"
echo "  - Delete after use if no longer needed"
echo ""

# Create README
cat > "$FULL_OUTPUT_PATH/README.md" << EOF
# Kubernetes Secrets Export

**⚠️ WARNING: This directory contains PLAIN TEXT secrets!**

## Security Guidelines

1. **NEVER commit these files to version control**
2. **Secure with proper file permissions**
3. **Delete after use if no longer needed**
4. **Share only through secure channels**

## Files

Exported on: $(date '+%Y-%m-%d %H:%M:%S')
Total secrets: $EXPORT_COUNT

Each file is organized by namespace and contains decoded secret values.

## Re-importing Secrets

To re-import a secret into Kubernetes:

\`\`\`bash
kubectl apply -f ./namespace/secret-name.yml
\`\`\`

## Cleanup

To remove all exported files:

\`\`\`bash
rm -rf ./KubeSecrets
\`\`\`
EOF

echo -e "${GREEN}Created README.md with security guidelines${NC}"
