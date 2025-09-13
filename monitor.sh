#!/bin/bash
set -eo pipefail

# Configuration from environment
BUILD_MODE=${BUILD_MODE:-"on_release"}  # "on_release" or "monthly"
MONTHLY_RELEASE=${MONTHLY_RELEASE:-1}  # Which release of the month to build (1st, 2nd, etc.)
CHECK_INTERVAL=${CHECK_INTERVAL:-3600}  # Check interval in seconds (default: 1 hour)
MONITORING_ENABLED=${MONITORING_ENABLED:-false}  # Enable/disable monitoring
STATE_FILE="/tmp/galley_monitor_state.json"
MONTHLY_BUILD_FILE="/tmp/galley_monthly_build.json"

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;33m'
export BLUE='\033[0;36m'
export YELLOW='\033[1;33m'
export NC='\033[0m'

# Helper functions
log_step() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR: $*${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR ERROR: $*${NC}" >&2
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR: $*${NC}"
}

notify() {
    local message="$1"
    if [[ -n "$APPRISE_URLS" ]]; then
        apprise -t "The Galley Monitor" -b "$message" || true
    fi
}

# Initialize state file if it doesn't exist
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"last_tag":"","last_build_tag":"","last_check":""}' > "$STATE_FILE"
    fi
    if [[ ! -f "$MONTHLY_BUILD_FILE" ]]; then
        echo '{"current_month":"","releases_this_month":0,"built_this_month":false}' > "$MONTHLY_BUILD_FILE"
    fi
}

# Get current state
get_state() {
    local key="$1"
    jq -r ".$key // \"\"" "$STATE_FILE" 2>/dev/null || echo ""
}

# Update state
update_state() {
    local key="$1"
    local value="$2"
    local temp_file=$(mktemp)
    jq ".$key = \"$value\"" "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
}

# Get monthly build state
get_monthly_state() {
    local key="$1"
    jq -r ".$key // \"\"" "$MONTHLY_BUILD_FILE" 2>/dev/null || echo ""
}

# Update monthly build state
update_monthly_state() {
    local key="$1"
    local value="$2"
    local temp_file=$(mktemp)
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        jq ".$key = $value" "$MONTHLY_BUILD_FILE" > "$temp_file" && mv "$temp_file" "$MONTHLY_BUILD_FILE"
    else
        jq ".$key = \"$value\"" "$MONTHLY_BUILD_FILE" > "$temp_file" && mv "$temp_file" "$MONTHLY_BUILD_FILE"
    fi
}

# Check for new GrapheneOS tags
check_for_new_tags() {
    log_step "Checking for new GrapheneOS releases..."
    
    # Fetch latest tags from GitHub API
    local latest_tags=$(curl -s https://api.github.com/repos/GrapheneOS/platform_manifest/tags | jq -r '.[0:5] | .[].name' 2>/dev/null)
    
    if [[ -z "$latest_tags" ]]; then
        error "Failed to fetch tags from GitHub"
        return 1
    fi
    
    # Get the most recent tag
    local latest_tag=$(echo "$latest_tags" | head -n1)
    local last_known_tag=$(get_state "last_tag")
    
    log_step "Latest tag: $latest_tag"
    log_step "Last known tag: $last_known_tag"
    
    # Update last check time
    update_state "last_check" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    
    # Check if we have a new tag
    if [[ "$latest_tag" != "$last_known_tag" ]] && [[ -n "$latest_tag" ]]; then
        success "New release detected: $latest_tag"
        update_state "last_tag" "$latest_tag"
        
        # Handle monthly build tracking
        local current_month=$(date +"%Y-%m")
        local tracked_month=$(get_monthly_state "current_month")
        
        if [[ "$current_month" != "$tracked_month" ]]; then
            # New month, reset counters
            update_monthly_state "current_month" "$current_month"
            update_monthly_state "releases_this_month" 0
            update_monthly_state "built_this_month" false
        fi
        
        # Increment release counter for the month
        local releases_count=$(get_monthly_state "releases_this_month")
        releases_count=$((releases_count + 1))
        update_monthly_state "releases_this_month" "$releases_count"
        
        # Decide whether to build
        local should_build=false
        
        if [[ "$BUILD_MODE" == "on_release" ]]; then
            should_build=true
            log_step "Build mode: on_release - Will build for tag $latest_tag"
        elif [[ "$BUILD_MODE" == "monthly" ]]; then
            local built_this_month=$(get_monthly_state "built_this_month")
            if [[ "$built_this_month" == "false" ]] && [[ "$releases_count" -ge "$MONTHLY_RELEASE" ]]; then
                should_build=true
                update_monthly_state "built_this_month" true
                log_step "Build mode: monthly - This is release #$releases_count, target is #$MONTHLY_RELEASE - Will build"
            else
                log_step "Build mode: monthly - This is release #$releases_count, target is #$MONTHLY_RELEASE, already built: $built_this_month - Skipping"
            fi
        fi
        
        if [[ "$should_build" == true ]]; then
            return 0  # Signal to trigger build
        fi
    else
        log_step "No new releases detected"
    fi
    
    return 1  # No build needed
}

# Trigger a build
trigger_build() {
    local tag="$1"
    log_step "Triggering build for tag: $tag"
    notify "Starting build for GrapheneOS $tag"
    
    # Update the TAG environment variable for the build
    export TAG="$tag"
    
    # Update last build tag
    update_state "last_build_tag" "$tag"
    
    # Run the build script
    log_step "Executing build.sh..."
    if /build.sh; then
        success "Build completed successfully for $tag"
        notify "Build completed successfully for GrapheneOS $tag"
    else
        error "Build failed for $tag"
        notify "Build FAILED for GrapheneOS $tag - check logs"
    fi
}

# Main monitoring loop
main() {
    log_step "Starting GrapheneOS release monitor"
    log_step "Build mode: $BUILD_MODE"
    
    if [[ "$BUILD_MODE" == "monthly" ]]; then
        log_step "Will build on release #$MONTHLY_RELEASE of each month"
    fi
    
    log_step "Check interval: ${CHECK_INTERVAL}s"
    
    # Initialize state
    init_state
    
    # Check if monitoring is enabled
    if [[ "$MONITORING_ENABLED" != "true" ]]; then
        log_step "Monitoring disabled, running single build with existing configuration"
        /build.sh
        exit $?
    fi
    
    notify "Monitor started - Mode: $BUILD_MODE"
    
    # Main loop
    while true; do
        if check_for_new_tags; then
            # New tag found and should build
            local latest_tag=$(get_state "last_tag")
            trigger_build "$latest_tag"
        fi
        
        log_step "Sleeping for ${CHECK_INTERVAL}s..."
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals for graceful shutdown
trap 'log_step "Received shutdown signal, exiting..."; exit 0' SIGTERM SIGINT

# Run main function
main "$@"