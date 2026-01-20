#!/bin/bash

# Uninstall script for Muesli
# Completely removes all traces of Muesli from the system
# Usage: ./scripts/uninstall.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arrays to store discovered items
declare -a APP_BUNDLES=()
declare -a APP_BUNDLE_IDS=()
declare -a APP_BUNDLE_TYPES=()
declare -a SELECTED_BUNDLES=()
declare -a DERIVED_DATA_FOLDERS=()

# Variables for recordings
RECORDINGS_DIR="$HOME/Library/Application Support/Muesli/Recordings"
RECORDINGS_COUNT=0
RECORDING_ACTION=""
RECORDING_DESTINATION=""

# Variables for application support
APP_SUPPORT_DIR="$HOME/Library/Application Support/Muesli"
APP_SUPPORT_ACTION=""

# Exit codes
EXIT_SUCCESS=0
EXIT_CANCELLED=1
EXIT_ERROR=2

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "$1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Check if running as root (should not be)
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        print_error "Do not run this script as root!"
        exit $EXIT_ERROR
    fi
}

# ============================================================================
# DISCOVERY FUNCTIONS
# ============================================================================

find_app_bundles() {
    print_info "Searching for Muesli app bundles..."
    
    # Search in DerivedData Debug builds
    local debug_dir="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$debug_dir" ]; then
        while IFS= read -r -d '' app; do
            local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
            APP_BUNDLES+=("$app")
            APP_BUNDLE_IDS+=("$bundle_id")
            APP_BUNDLE_TYPES+=("Debug")
        done < <(find "$debug_dir" -maxdepth 5 -name "Muesli*.app" -type d -print0 2>/dev/null)
    fi
    
    # Search in /Applications
    local apps_dir="/Applications"
    if [ -d "$apps_dir" ]; then
        while IFS= read -r -d '' app; do
            local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
            APP_BUNDLES+=("$app")
            APP_BUNDLE_IDS+=("$bundle_id")
            APP_BUNDLE_TYPES+=("Installed")
        done < <(find "$apps_dir" -maxdepth 1 -name "Muesli*.app" -type d -print0 2>/dev/null)
    fi
    
    print_info "Found ${#APP_BUNDLES[@]} app bundle(s)"
}

find_derived_data() {
    print_info "Searching for DerivedData folders..."
    
    local derived_data_dir="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$derived_data_dir" ]; then
        while IFS= read -r -d '' dir; do
            DERIVED_DATA_FOLDERS+=("$dir")
        done < <(find "$derived_data_dir" -maxdepth 1 -name "Muesli-*" -type d -print0 2>/dev/null)
    fi
    
    print_info "Found ${#DERIVED_DATA_FOLDERS[@]} DerivedData folder(s)"
}

count_recordings() {
    if [ -d "$RECORDINGS_DIR" ]; then
        RECORDINGS_COUNT=$(find "$RECORDINGS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    else
        RECORDINGS_COUNT=0
    fi
}

# ============================================================================
# INTERACTIVE SELECTION FUNCTIONS
# ============================================================================

interactive_select_bundles() {
    if [ ${#APP_BUNDLES[@]} -eq 0 ]; then
        print_warning "No app bundles found to select"
        return
    fi
    
    print_header "SELECT APP BUNDLES TO REMOVE"
    
    echo "Found the following Muesli installations:"
    echo ""
    
    # Initialize all as selected
    local -a selected=()
    for i in "${!APP_BUNDLES[@]}"; do
        selected[$i]=1
    done
    
    # Display bundles
    for i in "${!APP_BUNDLES[@]}"; do
        local app="${APP_BUNDLES[$i]}"
        local bundle_id="${APP_BUNDLE_IDS[$i]}"
        local build_type="${APP_BUNDLE_TYPES[$i]}"
        local app_name=$(basename "$app")
        
        if [ "${selected[$i]}" -eq 1 ]; then
            echo "  [x] $((i+1)). $app_name ($bundle_id) - $build_type"
        else
            echo "  [ ] $((i+1)). $app_name ($bundle_id) - $build_type"
        fi
    done
    
    echo ""
    echo "Enter numbers to toggle selection (e.g., '1 3' to toggle 1 and 3),"
    echo "or press Enter to continue with current selection,"
    echo "or 'all' to select all, 'none' to deselect all:"
    
    while true; do
        read -p "> " input
        
        if [ -z "$input" ]; then
            # Empty input - continue with current selection
            break
        elif [ "$input" = "all" ]; then
            for i in "${!APP_BUNDLES[@]}"; do
                selected[$i]=1
            done
            # Redisplay
            echo ""
            for i in "${!APP_BUNDLES[@]}"; do
                local app="${APP_BUNDLES[$i]}"
                local bundle_id="${APP_BUNDLE_IDS[$i]}"
                local build_type="${APP_BUNDLE_TYPES[$i]}"
                local app_name=$(basename "$app")
                echo "  [x] $((i+1)). $app_name ($bundle_id) - $build_type"
            done
            echo ""
        elif [ "$input" = "none" ]; then
            for i in "${!APP_BUNDLES[@]}"; do
                selected[$i]=0
            done
            # Redisplay
            echo ""
            for i in "${!APP_BUNDLES[@]}"; do
                local app="${APP_BUNDLES[$i]}"
                local bundle_id="${APP_BUNDLE_IDS[$i]}"
                local build_type="${APP_BUNDLE_TYPES[$i]}"
                local app_name=$(basename "$app")
                echo "  [ ] $((i+1)). $app_name ($bundle_id) - $build_type"
            done
            echo ""
        else
            # Toggle specific numbers
            for num in $input; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#APP_BUNDLES[@]} ]; then
                    local idx=$((num-1))
                    if [ "${selected[$idx]}" -eq 1 ]; then
                        selected[$idx]=0
                    else
                        selected[$idx]=1
                    fi
                fi
            done
            # Redisplay
            echo ""
            for i in "${!APP_BUNDLES[@]}"; do
                local app="${APP_BUNDLES[$i]}"
                local bundle_id="${APP_BUNDLE_IDS[$i]}"
                local build_type="${APP_BUNDLE_TYPES[$i]}"
                local app_name=$(basename "$app")
                if [ "${selected[$i]}" -eq 1 ]; then
                    echo "  [x] $((i+1)). $app_name ($bundle_id) - $build_type"
                else
                    echo "  [ ] $((i+1)). $app_name ($bundle_id) - $build_type"
                fi
            done
            echo ""
        fi
    done
    
    # Build final selection list
    SELECTED_BUNDLES=()
    for i in "${!APP_BUNDLES[@]}"; do
        if [ "${selected[$i]}" -eq 1 ]; then
            SELECTED_BUNDLES+=("$i")
        fi
    done
    
    if [ ${#SELECTED_BUNDLES[@]} -eq 0 ]; then
        print_warning "No bundles selected"
    else
        print_success "Selected ${#SELECTED_BUNDLES[@]} bundle(s)"
    fi
}

prompt_recording_action() {
    if [ "$RECORDINGS_COUNT" -eq 0 ]; then
        RECORDING_ACTION="none"
        return
    fi
    
    print_header "MEETING RECORDINGS"
    
    echo "Found $RECORDINGS_COUNT meeting recording(s) in:"
    echo "  $RECORDINGS_DIR"
    echo ""
    echo "What would you like to do with these recordings?"
    echo ""
    echo "  1. Delete all recordings"
    echo "  2. Move recordings to another location"
    echo "  3. Keep recordings (only remove app and settings)"
    echo ""
    
    while true; do
        read -p "Choice (1-3): " choice
        
        case "$choice" in
            1)
                RECORDING_ACTION="delete"
                print_warning "Recordings will be DELETED"
                break
                ;;
            2)
                RECORDING_ACTION="move"
                while true; do
                    read -p "Enter destination folder: " dest
                    # Expand tilde
                    dest="${dest/#\~/$HOME}"
                    
                    if [ -z "$dest" ]; then
                        print_error "Please enter a destination folder"
                        continue
                    fi
                    
                    # If destination doesn't exist, ask to create
                    if [ ! -d "$dest" ]; then
                        read -p "Folder doesn't exist. Create it? (y/n) " create
                        if [[ "$create" =~ ^[Yy]$ ]]; then
                            if mkdir -p "$dest" 2>/dev/null; then
                                RECORDING_DESTINATION="$dest"
                                print_success "Will move recordings to: $dest"
                                break 2
                            else
                                print_error "Failed to create folder: $dest"
                                continue
                            fi
                        else
                            continue
                        fi
                    else
                        RECORDING_DESTINATION="$dest"
                        print_success "Will move recordings to: $dest"
                        break 2
                    fi
                done
                ;;
            3)
                RECORDING_ACTION="keep"
                print_info "Recordings will be kept"
                break
                ;;
            *)
                print_error "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

prompt_app_support_action() {
    # Skip if we already chose to keep recordings (which means keeping App Support)
    if [ "$RECORDING_ACTION" = "keep" ]; then
        APP_SUPPORT_ACTION="keep"
        return
    fi
    
    # Skip if Application Support folder doesn't exist
    if [ ! -d "$APP_SUPPORT_DIR" ]; then
        APP_SUPPORT_ACTION="none"
        return
    fi
    
    print_header "APPLICATION SUPPORT FILES"
    
    echo "The Application Support folder may contain:"
    echo "  - Settings and preferences"
    echo "  - Cached data"
    echo "  - Downloaded models"
    echo ""
    echo "Location: ~/Library/Application Support/Muesli/"
    echo ""
    echo "Would you like to remove application support files?"
    echo ""
    echo "  1. Yes, remove all application support files"
    echo "  2. No, keep application support files (preserves settings for reinstall)"
    echo ""
    
    while true; do
        read -p "Choice (1-2): " choice
        
        case "$choice" in
            1)
                APP_SUPPORT_ACTION="delete"
                print_warning "Application support files will be DELETED"
                break
                ;;
            2)
                APP_SUPPORT_ACTION="keep"
                print_info "Application support files will be kept"
                break
                ;;
            *)
                print_error "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

# ============================================================================
# SUMMARY AND CONFIRMATION
# ============================================================================

show_summary() {
    print_header "UNINSTALL SUMMARY"
    
    local has_items=0
    
    # App Bundles
    if [ ${#SELECTED_BUNDLES[@]} -gt 0 ]; then
        has_items=1
        echo "Will DELETE:"
        echo "  App Bundles (${#SELECTED_BUNDLES[@]}):"
        for idx in "${SELECTED_BUNDLES[@]}"; do
            local app="${APP_BUNDLES[$idx]}"
            local bundle_id="${APP_BUNDLE_IDS[$idx]}"
            local build_type="${APP_BUNDLE_TYPES[$idx]}"
            local app_name=$(basename "$app")
            echo "    - $build_type/$app_name ($bundle_id)"
        done
        echo ""
    fi
    
    # DerivedData
    if [ ${#DERIVED_DATA_FOLDERS[@]} -gt 0 ]; then
        has_items=1
        echo "  DerivedData (${#DERIVED_DATA_FOLDERS[@]} folders):"
        for folder in "${DERIVED_DATA_FOLDERS[@]}"; do
            local folder_name=$(basename "$folder")
            echo "    - $folder_name"
        done
        echo ""
    fi
    
    # TCC Permissions
    if [ ${#SELECTED_BUNDLES[@]} -gt 0 ]; then
        echo "  TCC Permissions:"
        local unique_ids=()
        for idx in "${SELECTED_BUNDLES[@]}"; do
            local bundle_id="${APP_BUNDLE_IDS[$idx]}"
            if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
                unique_ids+=("$bundle_id")
            fi
        done
        echo "    - Screen Recording for: ${unique_ids[*]}"
        echo "    - Microphone for: ${unique_ids[*]}"
        echo ""
    fi
    
    # UserDefaults
    if [ ${#SELECTED_BUNDLES[@]} -gt 0 ]; then
        echo "  UserDefaults:"
        local unique_ids=()
        for idx in "${SELECTED_BUNDLES[@]}"; do
            local bundle_id="${APP_BUNDLE_IDS[$idx]}"
            if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
                unique_ids+=("$bundle_id")
                echo "    - $bundle_id"
            fi
        done
        echo ""
    fi
    
    # Recordings
    if [ "$RECORDING_ACTION" = "move" ] && [ -n "$RECORDING_DESTINATION" ]; then
        has_items=1
        echo "Will MOVE:"
        echo "  Meeting Recordings ($RECORDINGS_COUNT recordings):"
        echo "    FROM: $RECORDINGS_DIR"
        echo "    TO:   $RECORDING_DESTINATION"
        echo ""
    elif [ "$RECORDING_ACTION" = "delete" ]; then
        has_items=1
        echo "Will DELETE:"
        echo "  Meeting Recordings:"
        echo "    - $RECORDINGS_COUNT recording(s) in $RECORDINGS_DIR"
    fi
    
    # Application Support
    if [ "$APP_SUPPORT_ACTION" = "delete" ]; then
        has_items=1
        echo "Will DELETE:"
        echo "  Application Support:"
        if [ "$RECORDING_ACTION" = "move" ]; then
            echo "    - ~/Library/Application Support/Muesli/ (after moving recordings)"
        else
            echo "    - ~/Library/Application Support/Muesli/"
        fi
        echo ""
    elif [ "$APP_SUPPORT_ACTION" = "keep" ]; then
        echo "Will KEEP:"
        echo "  Application Support:"
        echo "    - ~/Library/Application Support/Muesli/"
        echo ""
    fi
    
    if [ $has_items -eq 0 ]; then
        echo "No items selected for removal."
        echo ""
        return 1
    fi
    
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${RED}WARNING: This action cannot be undone (except for moved recordings)${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    return 0
}

confirm_uninstall() {
    while true; do
        read -p "Continue with uninstall? (yes/no): " response
        case "$response" in
            yes|YES|y|Y)
                return 0
                ;;
            no|NO|n|N)
                return 1
                ;;
            *)
                print_error "Please answer 'yes' or 'no'"
                ;;
        esac
    done
}

# ============================================================================
# EXECUTION FUNCTIONS
# ============================================================================

kill_muesli_processes() {
    print_info "Killing running Muesli processes..."
    
    local killed=0
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local app="${APP_BUNDLES[$idx]}"
        local app_name=$(basename "$app" .app)
        
        if killall "$app_name" 2>/dev/null; then
            print_success "Killed: $app_name"
            killed=$((killed + 1))
        fi
    done
    
    if [ $killed -eq 0 ]; then
        print_info "No running processes found"
    fi
}

move_recordings() {
    if [ "$RECORDING_ACTION" != "move" ] || [ -z "$RECORDING_DESTINATION" ]; then
        return 0
    fi
    
    print_info "Moving recordings to $RECORDING_DESTINATION..."
    
    if [ ! -d "$RECORDINGS_DIR" ]; then
        print_warning "Recordings directory not found"
        return 0
    fi
    
    # Create a Recordings subfolder in destination
    local dest_recordings="$RECORDING_DESTINATION/Recordings"
    if ! mkdir -p "$dest_recordings" 2>/dev/null; then
        print_error "Failed to create destination: $dest_recordings"
        return 1
    fi
    
    # Move all recording folders
    local moved=0
    local failed=0
    while IFS= read -r -d '' recording; do
        local recording_name=$(basename "$recording")
        if mv "$recording" "$dest_recordings/" 2>/dev/null; then
            moved=$((moved + 1))
        else
            print_error "Failed to move: $recording_name"
            failed=$((failed + 1))
        fi
    done < <(find "$RECORDINGS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    
    print_success "Moved $moved recording(s)"
    if [ $failed -gt 0 ]; then
        print_warning "$failed recording(s) failed to move"
        return 1
    fi
    
    return 0
}

delete_app_bundles() {
    if [ ${#SELECTED_BUNDLES[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Deleting app bundles..."
    
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local app="${APP_BUNDLES[$idx]}"
        local app_name=$(basename "$app")
        
        if rm -rf "$app" 2>/dev/null; then
            print_success "Deleted: $app_name"
        else
            print_error "Failed to delete: $app_name"
        fi
    done
}

delete_derived_data() {
    if [ ${#DERIVED_DATA_FOLDERS[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Deleting DerivedData folders..."
    
    for folder in "${DERIVED_DATA_FOLDERS[@]}"; do
        local folder_name=$(basename "$folder")
        
        if rm -rf "$folder" 2>/dev/null; then
            print_success "Deleted: $folder_name"
        else
            print_error "Failed to delete: $folder_name"
        fi
    done
}

reset_tcc_permissions() {
    if [ ${#SELECTED_BUNDLES[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Resetting TCC permissions..."
    
    # Get unique bundle IDs
    local unique_ids=()
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local bundle_id="${APP_BUNDLE_IDS[$idx]}"
        if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
            unique_ids+=("$bundle_id")
        fi
    done
    
    for bundle_id in "${unique_ids[@]}"; do
        # Reset Screen Recording permission
        if tccutil reset ScreenCapture "$bundle_id" 2>/dev/null; then
            print_success "Reset Screen Recording for: $bundle_id"
        else
            print_warning "Could not reset Screen Recording for: $bundle_id"
        fi
        
        # Reset Microphone permission
        if tccutil reset Microphone "$bundle_id" 2>/dev/null; then
            print_success "Reset Microphone for: $bundle_id"
        else
            print_warning "Could not reset Microphone for: $bundle_id"
        fi
    done
}

delete_user_defaults() {
    if [ ${#SELECTED_BUNDLES[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Deleting UserDefaults..."
    
    # Get unique bundle IDs
    local unique_ids=()
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local bundle_id="${APP_BUNDLE_IDS[$idx]}"
        if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
            unique_ids+=("$bundle_id")
        fi
    done
    
    for bundle_id in "${unique_ids[@]}"; do
        if defaults delete "$bundle_id" 2>/dev/null; then
            print_success "Deleted UserDefaults for: $bundle_id"
        else
            print_info "No UserDefaults found for: $bundle_id"
        fi
    done
}

delete_application_support() {
    if [ "$APP_SUPPORT_ACTION" = "keep" ]; then
        print_info "Skipping Application Support (user chose to keep)"
        return 0
    fi
    
    if [ ! -d "$APP_SUPPORT_DIR" ]; then
        print_info "Application Support folder not found"
        return 0
    fi
    
    print_info "Deleting Application Support folder..."
    
    if rm -rf "$APP_SUPPORT_DIR" 2>/dev/null; then
        print_success "Deleted: ~/Library/Application Support/Muesli"
    else
        print_error "Failed to delete Application Support folder"
        return 1
    fi
}

execute_uninstall() {
    print_header "EXECUTING UNINSTALL"
    
    local success=0
    
    # Move recordings first (if requested)
    if [ "$RECORDING_ACTION" = "move" ]; then
        move_recordings || print_warning "Recording move failed, continuing with uninstall..."
    fi
    
    # Kill running processes
    kill_muesli_processes
    
    # Delete app bundles
    delete_app_bundles
    
    # Delete DerivedData
    delete_derived_data
    
    # Reset TCC permissions
    reset_tcc_permissions
    
    # Delete UserDefaults
    delete_user_defaults
    
    # Delete Application Support (unless keeping recordings)
    delete_application_support || print_warning "Application Support deletion failed, continuing..."
    
    print_header "UNINSTALL COMPLETE"
    
    if [ "$RECORDING_ACTION" = "move" ] && [ -n "$RECORDING_DESTINATION" ]; then
        print_info "Recordings saved to: $RECORDING_DESTINATION/Recordings"
    fi
    
    print_success "Muesli has been uninstalled from your system"
    echo ""
    echo "You can now:"
    echo "  - Test a clean installation from DMG"
    echo "  - Build fresh from Xcode"
    echo "  - Test the onboarding flow"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    clear
    
    print_header "MUESLI UNINSTALLER"
    
    # Safety check
    check_not_root
    
    # Discovery phase
    find_app_bundles
    find_derived_data
    count_recordings
    
    # Check if anything was found
    if [ ${#APP_BUNDLES[@]} -eq 0 ] && [ ${#DERIVED_DATA_FOLDERS[@]} -eq 0 ] && [ "$RECORDINGS_COUNT" -eq 0 ]; then
        print_warning "No Muesli installations found"
        echo ""
        echo "Searched in:"
        echo "  - ~/Library/Developer/Xcode/DerivedData/"
        echo "  - /Applications/"
        echo "  - ~/Library/Application Support/Muesli/"
        echo ""
        exit $EXIT_SUCCESS
    fi
    
    # Interactive selection
    if [ ${#APP_BUNDLES[@]} -gt 0 ]; then
        interactive_select_bundles
    fi
    
    # Recording handling
    if [ "$RECORDINGS_COUNT" -gt 0 ]; then
        prompt_recording_action
    else
        RECORDING_ACTION="none"
    fi
    
    # Application Support handling (separate from recordings)
    prompt_app_support_action
    
    # Show summary and confirm
    if ! show_summary; then
        print_warning "Nothing selected to uninstall"
        exit $EXIT_CANCELLED
    fi
    
    if ! confirm_uninstall; then
        print_info "Uninstall cancelled by user"
        exit $EXIT_CANCELLED
    fi
    
    # Execute uninstall
    execute_uninstall
    
    exit $EXIT_SUCCESS
}

# Run main
main
