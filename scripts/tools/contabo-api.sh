#!/bin/bash
# Contabo API Helper Script
# Provides functions to interact with Contabo API for VPS management

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Contabo API endpoints
# Using the correct Contabo auth endpoint (matches contabo_auth_token.sh)
CONTABO_AUTH_URL="https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token"
CONTABO_API_URL="https://api.contabo.com/v1/compute/instances"

# Function to get Contabo OAuth token
get_contabo_token() {
    local CLIENT_ID="${CONTABO_CLIENT_ID:-}"
    local CLIENT_SECRET="${CONTABO_CLIENT_SECRET:-}"
    local USERNAME="${CONTABO_API_USERNAME:-}"
    local PASSWORD="${CONTABO_API_PASSWORD:-}"
    
    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
        echo -e "${RED}❌ Missing Contabo API credentials${NC}"
        echo -e "${YELLOW}Required: CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET, CONTABO_API_USERNAME, CONTABO_API_PASSWORD${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Getting Contabo OAuth token...${NC}"
    
    local RESPONSE=$(curl -s -X POST "$CONTABO_AUTH_URL" \
        -d "client_id=${CLIENT_ID}" \
        -d "client_secret=${CLIENT_SECRET}" \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "password=${PASSWORD}" \
        -d "grant_type=password" || echo "")
    
    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}❌ Failed to connect to Contabo API${NC}"
        return 1
    fi
    
    # Check for error in response
    if echo "$RESPONSE" | grep -q "error"; then
        echo -e "${RED}❌ Contabo API error:${NC}"
        echo "$RESPONSE" | jq -r '.error_description // .error' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    # Extract access token
    local ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token' 2>/dev/null || echo "")
    
    if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
        echo -e "${RED}❌ Failed to get access token${NC}"
        echo "Response: $RESPONSE"
        return 1
    fi
    
    echo "$ACCESS_TOKEN"
    return 0
}

# Function to get VPS IP from Contabo API
get_vps_ip_from_contabo() {
    local INSTANCE_ID="${CONTABO_INSTANCE_ID:-}"
    local ACCESS_TOKEN="${1:-}"
    
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(get_contabo_token)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    echo -e "${BLUE}Fetching VPS instance information from Contabo...${NC}"
    
    # If instance ID is provided, get specific instance
    if [ -n "$INSTANCE_ID" ]; then
        local RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "${CONTABO_API_URL}/${INSTANCE_ID}" || echo "")
    else
        # Otherwise, list all instances and get the first one
        local RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "$CONTABO_API_URL" || echo "")
    fi
    
    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}❌ Failed to fetch instance information${NC}"
        return 1
    fi
    
    # Check for error in response
    if echo "$RESPONSE" | grep -q "error"; then
        echo -e "${RED}❌ Contabo API error:${NC}"
        echo "$RESPONSE" | jq -r '.error_description // .error' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    # Extract IP address
    # Try to get public IP from instance data
    local IP=$(echo "$RESPONSE" | jq -r '.data[0].ipConfig.ipV4.ip // .data.ipConfig.ipV4.ip // .ipConfig.ipV4.ip // empty' 2>/dev/null || echo "")
    
    # If no IP found, try alternative paths
    if [ -z "$IP" ] || [ "$IP" = "null" ]; then
        IP=$(echo "$RESPONSE" | jq -r '.data[0].ipV4Address // .data.ipV4Address // .ipV4Address // empty' 2>/dev/null || echo "")
    fi
    
    if [ -z "$IP" ] || [ "$IP" = "null" ]; then
        echo -e "${YELLOW}⚠️  Could not extract IP from Contabo API response${NC}"
        echo -e "${BLUE}Response structure:${NC}"
        echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    echo -e "${GREEN}✓ Found VPS IP: ${IP}${NC}" >&2
    # Output only the IP address (no colors) to stdout for easy parsing
    echo "$IP"
    return 0
}

# Function to check if VPS is running
check_vps_status() {
    local INSTANCE_ID="${CONTABO_INSTANCE_ID:-}"
    local ACCESS_TOKEN="${1:-}"
    
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(get_contabo_token)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    echo -e "${BLUE}Checking VPS status...${NC}"
    
    local RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${CONTABO_API_URL}/${INSTANCE_ID}" || echo "")
    
    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}❌ Failed to check VPS status${NC}"
        return 1
    fi
    
    local STATUS=$(echo "$RESPONSE" | jq -r '.data.status // .status // empty' 2>/dev/null || echo "")
    
    if [ -z "$STATUS" ] || [ "$STATUS" = "null" ]; then
        echo -e "${YELLOW}⚠️  Could not determine VPS status${NC}"
        return 1
    fi
    
    echo -e "${BLUE}VPS Status: ${STATUS}${NC}"
    
    if [ "$STATUS" = "running" ]; then
        return 0
    else
        return 1
    fi
}

# Function to start VPS if stopped
start_vps_if_stopped() {
    local INSTANCE_ID="${CONTABO_INSTANCE_ID:-}"
    local ACCESS_TOKEN="${1:-}"
    
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(get_contabo_token)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Check current status
    if check_vps_status "$ACCESS_TOKEN"; then
        echo -e "${GREEN}✓ VPS is already running${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}VPS is not running. Attempting to start...${NC}"
    
    local RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CONTABO_API_URL}/${INSTANCE_ID}/actions/start" || echo "")
    
    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}❌ Failed to start VPS${NC}"
        return 1
    fi
    
    # Check for error
    if echo "$RESPONSE" | grep -q "error"; then
        echo -e "${RED}❌ Failed to start VPS:${NC}"
        echo "$RESPONSE" | jq -r '.error_description // .error' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    echo -e "${GREEN}✓ VPS start command sent${NC}"
    echo -e "${BLUE}Waiting for VPS to start (this may take 30-60 seconds)...${NC}"
    
    # Wait for VPS to start (max 2 minutes)
    local MAX_WAIT=120
    local ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        if check_vps_status "$ACCESS_TOKEN" 2>/dev/null; then
            echo -e "${GREEN}✓ VPS is now running${NC}"
            return 0
        fi
        echo -e "${BLUE}Still waiting... (${ELAPSED}s/${MAX_WAIT}s)${NC}"
    done
    
    echo -e "${YELLOW}⚠️  VPS start timeout. It may still be starting.${NC}"
    return 1
}

# Function to ensure VPS is running (start if stopped, wait until ready)
ensure_vps_running() {
    local INSTANCE_ID="${CONTABO_INSTANCE_ID:-}"
    local ACCESS_TOKEN="${1:-}"
    
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(get_contabo_token)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Check and start if needed
    if ! check_vps_status "$ACCESS_TOKEN"; then
        start_vps_if_stopped "$ACCESS_TOKEN"
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Additional wait to ensure VPS is fully ready
    echo -e "${BLUE}Ensuring VPS is fully ready...${NC}"
    sleep 10
    
    return 0
}

# Function to get VPS instance details
get_vps_details() {
    local INSTANCE_ID="${CONTABO_INSTANCE_ID:-14285715}"
    local ACCESS_TOKEN="${1:-}"
    
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(get_contabo_token)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    if [ -z "$INSTANCE_ID" ]; then
        echo -e "${RED}❌ CONTABO_INSTANCE_ID not set${NC}"
        return 1
    fi
    
    local RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${CONTABO_API_URL}/${INSTANCE_ID}" || echo "")
    
    if [ -z "$RESPONSE" ]; then
        echo -e "${RED}❌ Failed to fetch instance details${NC}"
        return 1
    fi
    
    # Check for error
    if echo "$RESPONSE" | grep -q "error"; then
        echo -e "${RED}❌ Contabo API error:${NC}"
        echo "$RESPONSE" | jq -r '.error_description // .error' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
    
    echo "$RESPONSE"
    return 0
}

# Main function - get VPS IP with Contabo API fallback
main() {
    local ACTION="${1:-get_ip}"
    
    case "$ACTION" in
        get_ip)
            get_vps_ip_from_contabo
            ;;
        get_token)
            get_contabo_token
            ;;
        check_status)
            check_vps_status
            ;;
        start)
            start_vps_if_stopped
            ;;
        ensure_running)
            ensure_vps_running
            ;;
        get_details)
            get_vps_details
            ;;
        *)
            echo "Usage: $0 {get_ip|get_token|check_status|start|ensure_running|get_details}"
            exit 1
            ;;
    esac
}

# If script is executed directly (not sourced), run main
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

