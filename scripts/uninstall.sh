#!/bin/bash

# Uninstall script for Muesli
# Completely removes all traces of Muesli from the system
# Usage: ./scripts/uninstall.sh [--dry-run] [--yes]
#
# Options:
#   --dry-run    Preview what would be deleted without making changes
#   --yes        Non-interactive mode: delete everything without prompts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# CLI options
DRY_RUN=false
AUTO_YES=false
LOG_FILE="/tmp/muesli-uninstall-$(date +%Y%m%d-%H%M%S).log"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --help|-h)
            echo "Usage: ./scripts/uninstall.sh [--dry-run] [--yes]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Preview what would be deleted without making changes"
            echo "  --yes, -y    Non-interactive mode: delete everything without prompts"
            echo "  --help       Show this help message"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Logging function - logs all actions to file for troubleshooting
log_action() {
    local action="$1"
    local target="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action: $target" >> "$LOG_FILE"
}

# Wrapper for destructive operations - respects DRY_RUN mode
execute_or_preview() {
    local action="$1"
    local target="$2"
    local command="$3"
    
    log_action "$action" "$target"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN]${NC} Would $action: $target"
        return 0
    else
        eval "$command"
    fi
}

# Launch Services register path
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# Arrays to store discovered items
declare -a APP_BUNDLES=()
declare -a APP_BUNDLE_IDS=()
declare -a APP_BUNDLE_TYPES=()
declare -a SELECTED_BUNDLES=()
declare -a DERIVED_DATA_FOLDERS=()
declare -a SELECTED_DERIVED_DATA=()

# New arrays for comprehensive cleanup
declare -a MOUNTED_DMG_APPS=()
declare -a MOUNTED_DMG_VOLUMES=()
declare -a TRASH_APPS=()
declare -a USER_APPS=()
declare -a LOGIN_ITEMS=()
declare -a BUNDLE_CACHE_DIRS=()
declare -a BUNDLE_HTTP_DIRS=()
declare -a BUNDLE_PREF_FILES=()
declare -a PROJECT_BUILD_DIRS=()

# Flags for user choices on new items
DELETE_TRASH_APPS=false
EJECT_DMGS=false
CLEAN_PER_BUNDLE_ARTIFACTS=false

# Variables for recordings
RECORDINGS_DIR="$HOME/Library/Application Support/Muesli/Recordings"
RECORDINGS_COUNT=0
RECORDING_ACTION=""
RECORDING_DESTINATION=""

# Variables for application support
APP_SUPPORT_DIR="$HOME/Library/Application Support/Muesli"
APP_SUPPORT_ACTION=""

# Variables for models
MODELS_DIR="$HOME/Library/Application Support/Muesli/Models"
HUGGINGFACE_CACHE_DIR="$HOME/.cache/huggingface/hub"
KEEP_MODELS=false

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
    
    # Search in DerivedData Debug builds (Xcode default location)
    local debug_dir="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$debug_dir" ]; then
        while IFS= read -r -d '' app; do
            local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
            APP_BUNDLES+=("$app")
            APP_BUNDLE_IDS+=("$bundle_id")
            APP_BUNDLE_TYPES+=("Debug")
        done < <(find "$debug_dir" -maxdepth 5 -name "Muesli*.app" -type d -print0 2>/dev/null)
    fi
    
    # Search in project-local DerivedData (custom build location)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_dir="$(dirname "$script_dir")"
    local local_derived_data="$project_dir/DerivedData"
    if [ -d "$local_derived_data" ]; then
        while IFS= read -r -d '' app; do
            local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
            APP_BUNDLES+=("$app")
            APP_BUNDLE_IDS+=("$bundle_id")
            APP_BUNDLE_TYPES+=("Local Debug")
        done < <(find "$local_derived_data" -maxdepth 5 -name "Muesli*.app" -type d -print0 2>/dev/null)
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
    
    # Search in Xcode default DerivedData location
    local derived_data_dir="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$derived_data_dir" ]; then
        while IFS= read -r -d '' dir; do
            DERIVED_DATA_FOLDERS+=("$dir")
        done < <(find "$derived_data_dir" -maxdepth 1 -name "Muesli-*" -type d -print0 2>/dev/null)
    fi
    
    # Search for project-local DerivedData folder
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_dir="$(dirname "$script_dir")"
    local local_derived_data="$project_dir/DerivedData"
    if [ -d "$local_derived_data" ]; then
        DERIVED_DATA_FOLDERS+=("$local_derived_data")
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

find_user_applications_apps() {
    print_info "Searching in ~/Applications..."
    if [ -d "$HOME/Applications" ]; then
        while IFS= read -r -d '' app; do
            local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
            USER_APPS+=("$app")
            APP_BUNDLES+=("$app")
            APP_BUNDLE_IDS+=("$bundle_id")
            APP_BUNDLE_TYPES+=("User Installed")
        done < <(find "$HOME/Applications" -maxdepth 1 -name "Muesli*.app" -type d -print0 2>/dev/null)
    fi
    print_info "Found ${#USER_APPS[@]} app(s) in ~/Applications"
}

find_mounted_dmg_apps() {
    print_info "Searching for Muesli on mounted DMGs..."
    
    # Check /Volumes/Muesli* and /Volumes/dmg.* patterns
    for vol in /Volumes/Muesli* /Volumes/dmg.*; do
        if [ -d "$vol" ]; then
            while IFS= read -r -d '' app; do
                MOUNTED_DMG_APPS+=("$app")
                # Store the volume path (parent of app)
                local vol_path=$(dirname "$app")
                # Only add unique volumes
                if [[ ! " ${MOUNTED_DMG_VOLUMES[*]} " =~ " ${vol_path} " ]]; then
                    MOUNTED_DMG_VOLUMES+=("$vol_path")
                fi
            done < <(find "$vol" -maxdepth 1 -name "Muesli*.app" -type d -print0 2>/dev/null)
        fi
    done
    
    print_info "Found ${#MOUNTED_DMG_APPS[@]} app(s) on ${#MOUNTED_DMG_VOLUMES[@]} mounted DMG(s)"
}

find_trash_apps() {
    print_info "Searching for Muesli in Trash..."
    if [ -d "$HOME/.Trash" ]; then
        while IFS= read -r -d '' app; do
            TRASH_APPS+=("$app")
        done < <(find "$HOME/.Trash" -maxdepth 1 -name "Muesli*.app" -type d -print0 2>/dev/null)
    fi
    print_info "Found ${#TRASH_APPS[@]} app(s) in Trash"
}

find_login_items() {
    print_info "Searching for Login Items..."
    if [ -d "$HOME/Library/LaunchAgents" ]; then
        while IFS= read -r -d '' plist; do
            LOGIN_ITEMS+=("$plist")
        done < <(find "$HOME/Library/LaunchAgents" -maxdepth 1 -iname "*muesli*" -type f -print0 2>/dev/null)
    fi
    print_info "Found ${#LOGIN_ITEMS[@]} Login Item(s)"
}

find_per_bundle_artifacts() {
    print_info "Searching for per-bundle caches and preferences..."
    
    # Use tight pattern: exact match OR named suffix
    # This prevents matching unintended bundle IDs
    
    # Caches - ~/Library/Caches/
    if [ -d "$HOME/Library/Caches" ]; then
        while IFS= read -r -d '' dir; do
            BUNDLE_CACHE_DIRS+=("$dir")
        done < <(find "$HOME/Library/Caches" -maxdepth 1 -type d \( -name "com.muesli.app" -o -name "com.muesli.app.???" -o -name "com.muesli.app.*-*" \) -print0 2>/dev/null)
    fi
    
    # HTTP Storages - ~/Library/HTTPStorages/
    if [ -d "$HOME/Library/HTTPStorages" ]; then
        while IFS= read -r -d '' dir; do
            BUNDLE_HTTP_DIRS+=("$dir")
        done < <(find "$HOME/Library/HTTPStorages" -maxdepth 1 -type d \( -name "com.muesli.app" -o -name "com.muesli.app.???" -o -name "com.muesli.app.*-*" \) -print0 2>/dev/null)
    fi
    
    # Preference files - ~/Library/Preferences/
    if [ -d "$HOME/Library/Preferences" ]; then
        while IFS= read -r -d '' file; do
            BUNDLE_PREF_FILES+=("$file")
        done < <(find "$HOME/Library/Preferences" -maxdepth 1 -type f \( -name "com.muesli.app.plist" -o -name "com.muesli.app.???.plist" -o -name "com.muesli.app.*-*.plist" \) -print0 2>/dev/null)
    fi
    
    print_info "Found ${#BUNDLE_CACHE_DIRS[@]} cache dir(s), ${#BUNDLE_HTTP_DIRS[@]} HTTP storage(s), ${#BUNDLE_PREF_FILES[@]} pref file(s)"
}

find_project_build_dirs() {
    print_info "Searching for project build directories..."
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_dir="$(dirname "$script_dir")"
    
    # Check for build/ directory in project root
    if [ -d "$project_dir/build" ]; then
        PROJECT_BUILD_DIRS+=("$project_dir/build")
    fi
    
    print_info "Found ${#PROJECT_BUILD_DIRS[@]} project build dir(s)"
}

# ============================================================================
# INTERACTIVE SELECTION FUNCTIONS
# ============================================================================

interactive_select_bundles() {
    if [ ${#APP_BUNDLES[@]} -eq 0 ]; then
        print_warning "No app bundles found to select"
        return
    fi

    # Auto-yes: select all bundles
    if [ "$AUTO_YES" = true ]; then
        SELECTED_BUNDLES=()
        for i in "${!APP_BUNDLES[@]}"; do
            SELECTED_BUNDLES+=("$i")
        done
        print_info "Auto-selecting all ${#SELECTED_BUNDLES[@]} app bundle(s)"
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

interactive_select_derived_data() {
    if [ ${#DERIVED_DATA_FOLDERS[@]} -eq 0 ]; then
        return
    fi

    # Auto-yes: select all DerivedData folders
    if [ "$AUTO_YES" = true ]; then
        SELECTED_DERIVED_DATA=()
        for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
            SELECTED_DERIVED_DATA+=("$i")
        done
        print_info "Auto-selecting all ${#SELECTED_DERIVED_DATA[@]} DerivedData folder(s)"
        return
    fi

    print_header "DERIVEDDATA FOLDERS"

    echo "Found the following DerivedData folder(s):"
    echo ""

    local -a selected=()
    for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
        selected[$i]=1
    done

    for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
        local folder="${DERIVED_DATA_FOLDERS[$i]}"
        local folder_name=$(basename "$folder")
        local folder_size=$(du -sh "$folder" 2>/dev/null | cut -f1)

        if [ "${selected[$i]}" -eq 1 ]; then
            echo "  [x] $((i+1)). $folder_name ($folder_size)"
        else
            echo "  [ ] $((i+1)). $folder_name ($folder_size)"
        fi
    done

    echo ""
    echo "DerivedData contains build caches. Deleting saves disk space but"
    echo "requires a full rebuild (~5-8 min) next time."
    echo ""
    echo "Enter numbers to toggle, 'all'/'none', or Enter to continue:"

    while true; do
        read -p "> " input

        if [ -z "$input" ]; then
            break
        elif [ "$input" = "all" ]; then
            for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
                selected[$i]=1
            done
        elif [ "$input" = "none" ]; then
            for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
                selected[$i]=0
            done
        else
            for num in $input; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#DERIVED_DATA_FOLDERS[@]} ]; then
                    local idx=$((num-1))
                    if [ "${selected[$idx]}" -eq 1 ]; then
                        selected[$idx]=0
                    else
                        selected[$idx]=1
                    fi
                fi
            done
        fi

        # Redisplay
        echo ""
        for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
            local folder="${DERIVED_DATA_FOLDERS[$i]}"
            local folder_name=$(basename "$folder")
            local folder_size=$(du -sh "$folder" 2>/dev/null | cut -f1)
            if [ "${selected[$i]}" -eq 1 ]; then
                echo "  [x] $((i+1)). $folder_name ($folder_size)"
            else
                echo "  [ ] $((i+1)). $folder_name ($folder_size)"
            fi
        done
        echo ""
    done

    SELECTED_DERIVED_DATA=()
    for i in "${!DERIVED_DATA_FOLDERS[@]}"; do
        if [ "${selected[$i]}" -eq 1 ]; then
            SELECTED_DERIVED_DATA+=("$i")
        fi
    done

    if [ ${#SELECTED_DERIVED_DATA[@]} -eq 0 ]; then
        print_info "No DerivedData folders selected"
    else
        print_success "Selected ${#SELECTED_DERIVED_DATA[@]} DerivedData folder(s)"
    fi
}

prompt_recording_action() {
    if [ "$RECORDINGS_COUNT" -eq 0 ]; then
        RECORDING_ACTION="none"
        return
    fi

    # Auto-yes: delete all recordings
    if [ "$AUTO_YES" = true ]; then
        RECORDING_ACTION="delete"
        print_info "Auto-selecting: delete all recordings"
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

    # Auto-yes: delete everything
    if [ "$AUTO_YES" = true ]; then
        APP_SUPPORT_ACTION="delete"
        KEEP_MODELS=false
        print_info "Auto-selecting: delete all Application Support files"
        return
    fi

    print_header "APPLICATION SUPPORT FILES"
    
    echo "Found the following Muesli data in Application Support:"
    echo "  - Settings and preferences (UserDefaults)"
    echo "  - Diagnostic logs"
    echo "  - Downloaded WhisperKit models (~75MB - 3GB each)"
    echo ""
    echo "Location: ~/Library/Application Support/Muesli/"
    echo ""
    
    # Check if models exist
    local has_whisperkit_models=false
    local has_llm_models=false
    
    if [ -d "$MODELS_DIR" ] && [ -n "$(find "$MODELS_DIR" -name "*.mlmodelc" 2>/dev/null | head -1)" ]; then
        has_whisperkit_models=true
        echo -e "  ${BLUE}WhisperKit models found${NC}"
    fi
    
    if [ -d "$HUGGINGFACE_CACHE_DIR" ]; then
        # Check for Muesli-relevant LLM models (mlx-community models)
        if ls "$HUGGINGFACE_CACHE_DIR"/models--mlx-community--* >/dev/null 2>&1; then
            has_llm_models=true
            echo -e "  ${BLUE}LLM models found in ~/.cache/huggingface/hub/${NC}"
        fi
    fi
    
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1. Remove everything (settings, logs, and models)"
    echo "  2. Keep models only (remove settings/logs; keep models for faster reinstall)"
    echo "  3. Keep everything (preserves all data for reinstall)"
    echo ""
    
    while true; do
        read -p "Choice (1-3): " choice
        
        case "$choice" in
            1)
                APP_SUPPORT_ACTION="delete"
                KEEP_MODELS=false
                print_warning "All application support files will be DELETED (including models)"
                break
                ;;
            2)
                APP_SUPPORT_ACTION="delete"
                KEEP_MODELS=true
                print_info "Settings and logs will be deleted, models will be KEPT"
                break
                ;;
            3)
                APP_SUPPORT_ACTION="keep"
                print_info "All application support files will be kept"
                break
                ;;
            *)
                ;;
        esac
    done
}

prompt_mounted_dmg_action() {
    if [ ${#MOUNTED_DMG_APPS[@]} -eq 0 ]; then
        return
    fi

    # Auto-yes: eject all DMGs
    if [ "$AUTO_YES" = true ]; then
        EJECT_DMGS=true
        print_info "Auto-selecting: eject all mounted DMGs"
        return
    fi

    print_header "MOUNTED DMG VOLUMES"
    
    echo "Found ${#MOUNTED_DMG_APPS[@]} Muesli app(s) on mounted DMG volume(s):"
    echo ""
    
    for app in "${MOUNTED_DMG_APPS[@]}"; do
        local app_name=$(basename "$app")
        local vol_path=$(dirname "$app")
        local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
        echo "  - $app_name ($bundle_id)"
        echo "    Volume: $vol_path"
    done
    
    echo ""
    echo -e "${YELLOW}Apps on mounted DMGs can cause 'wrong version' launches.${NC}"
    echo "Ejecting these volumes will unregister them from Launch Services."
    echo ""
    
    while true; do
        read -p "Eject these DMG volumes? [y/n]: " response
        case "$response" in
            y|Y|yes|YES)
                EJECT_DMGS=true
                print_success "DMG volumes will be ejected"
                break
                ;;
            n|N|no|NO)
                EJECT_DMGS=false
                print_info "DMG volumes will be kept mounted"
                break
                ;;
            *)
                ;;
        esac
    done
}

prompt_trash_deletion() {
    if [ ${#TRASH_APPS[@]} -eq 0 ]; then
        return
    fi

    # Auto-yes: delete trash apps
    if [ "$AUTO_YES" = true ]; then
        DELETE_TRASH_APPS=true
        print_info "Auto-selecting: delete all Muesli apps from Trash"
        return
    fi

    print_header "APPS IN TRASH"
    
    echo -e "${RED}⚠️  WARNING: Deleting apps from Trash is PERMANENT.${NC}"
    echo -e "${RED}    These items cannot be recovered after deletion.${NC}"
    echo ""
    echo "Found ${#TRASH_APPS[@]} Muesli app(s) in Trash:"
    echo ""
    
    for app in "${TRASH_APPS[@]}"; do
        local app_name=$(basename "$app")
        local app_size=$(du -sh "$app" 2>/dev/null | cut -f1)
        local bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
        echo "  - $app_name ($bundle_id) - $app_size"
    done
    
    echo ""
    echo -e "${YELLOW}Apps in Trash can still be launched and cause 'wrong version' issues.${NC}"
    echo ""
    
    while true; do
        read -p "Delete these permanently? [y/n]: " response
        case "$response" in
            y|Y|yes|YES)
                DELETE_TRASH_APPS=true
                print_warning "Trash apps will be PERMANENTLY deleted"
                break
                ;;
            n|N|no|NO)
                DELETE_TRASH_APPS=false
                print_info "Trash apps will be kept"
                break
                ;;
            *)
                ;;
        esac
    done
}

prompt_per_bundle_artifacts() {
    local total_artifacts=$((${#BUNDLE_CACHE_DIRS[@]} + ${#BUNDLE_HTTP_DIRS[@]} + ${#BUNDLE_PREF_FILES[@]}))

    if [ $total_artifacts -eq 0 ]; then
        return
    fi

    # Auto-yes: clean all per-bundle artifacts
    if [ "$AUTO_YES" = true ]; then
        CLEAN_PER_BUNDLE_ARTIFACTS=true
        print_info "Auto-selecting: delete all per-bundle artifacts ($total_artifacts items)"
        return
    fi

    print_header "PER-BUNDLE ARTIFACTS"
    
    echo "Found artifacts from Muesli bundle ID variants:"
    echo ""
    
    if [ ${#BUNDLE_CACHE_DIRS[@]} -gt 0 ]; then
        local cache_size=$(du -shc "${BUNDLE_CACHE_DIRS[@]}" 2>/dev/null | tail -1 | cut -f1)
        echo "  Caches (${#BUNDLE_CACHE_DIRS[@]} dirs, ~$cache_size total):"
        for dir in "${BUNDLE_CACHE_DIRS[@]}"; do
            echo "    - $(basename "$dir")"
        done
        echo ""
    fi
    
    if [ ${#BUNDLE_HTTP_DIRS[@]} -gt 0 ]; then
        echo "  HTTP Storages (${#BUNDLE_HTTP_DIRS[@]} dirs):"
        for dir in "${BUNDLE_HTTP_DIRS[@]}"; do
            echo "    - $(basename "$dir")"
        done
        echo ""
    fi
    
    if [ ${#BUNDLE_PREF_FILES[@]} -gt 0 ]; then
        echo "  Preference Files (${#BUNDLE_PREF_FILES[@]} files):"
        for file in "${BUNDLE_PREF_FILES[@]}"; do
            echo "    - $(basename "$file")"
        done
        echo ""
    fi
    
    echo "These are caches and preferences from different Muesli builds."
    echo "Removing them is safe and can free up disk space."
    echo ""
    
    while true; do
        read -p "Delete these artifacts? [y/n]: " response
        case "$response" in
            y|Y|yes|YES)
                CLEAN_PER_BUNDLE_ARTIFACTS=true
                print_success "Per-bundle artifacts will be deleted"
                break
                ;;
            n|N|no|NO)
                CLEAN_PER_BUNDLE_ARTIFACTS=false
                print_info "Per-bundle artifacts will be kept"
                break
                ;;
            *)
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
    
    # Show DRY RUN notice at top if applicable
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}═══ DRY RUN MODE - No changes will be made ═══${NC}"
        echo ""
    fi
    
    echo "Will DELETE:"
    echo ""
    
    # App Bundles
    if [ ${#SELECTED_BUNDLES[@]} -gt 0 ]; then
        has_items=1
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
    
    # Trash Apps
    if [ "$DELETE_TRASH_APPS" = true ] && [ ${#TRASH_APPS[@]} -gt 0 ]; then
        has_items=1
        echo -e "  ${RED}Apps in Trash (PERMANENT):${NC}"
        for app in "${TRASH_APPS[@]}"; do
            local app_name=$(basename "$app")
            echo "    - $app_name"
        done
        echo ""
    fi
    
    # DerivedData
    if [ ${#SELECTED_DERIVED_DATA[@]} -gt 0 ]; then
        has_items=1
        echo "  DerivedData (${#SELECTED_DERIVED_DATA[@]} folders):"
        for idx in "${SELECTED_DERIVED_DATA[@]}"; do
            local folder="${DERIVED_DATA_FOLDERS[$idx]}"
            local folder_name=$(basename "$folder")
            echo "    - $folder_name"
        done
        echo ""
    fi
    
    # Project build directories
    if [ ${#PROJECT_BUILD_DIRS[@]} -gt 0 ]; then
        has_items=1
        echo "  Project Build Directories (${#PROJECT_BUILD_DIRS[@]}):"
        for dir in "${PROJECT_BUILD_DIRS[@]}"; do
            local dir_name=$(basename "$dir")
            echo "    - $dir_name"
        done
        echo ""
    fi
    
    # Per-bundle artifacts
    if [ "$CLEAN_PER_BUNDLE_ARTIFACTS" = true ]; then
        local total=$((${#BUNDLE_CACHE_DIRS[@]} + ${#BUNDLE_HTTP_DIRS[@]} + ${#BUNDLE_PREF_FILES[@]}))
        if [ $total -gt 0 ]; then
            has_items=1
            echo "  Per-Bundle Artifacts ($total items):"
            if [ ${#BUNDLE_CACHE_DIRS[@]} -gt 0 ]; then
                echo "    - ${#BUNDLE_CACHE_DIRS[@]} cache directories"
            fi
            if [ ${#BUNDLE_HTTP_DIRS[@]} -gt 0 ]; then
                echo "    - ${#BUNDLE_HTTP_DIRS[@]} HTTP storage directories"
            fi
            if [ ${#BUNDLE_PREF_FILES[@]} -gt 0 ]; then
                echo "    - ${#BUNDLE_PREF_FILES[@]} preference files"
            fi
            echo ""
        fi
    fi
    
    # Login Items
    if [ ${#LOGIN_ITEMS[@]} -gt 0 ]; then
        has_items=1
        echo "  Login Items (${#LOGIN_ITEMS[@]}):"
        for plist in "${LOGIN_ITEMS[@]}"; do
            local plist_name=$(basename "$plist")
            echo "    - $plist_name"
        done
        echo ""
    fi
    
    # TCC Permissions (always reset — entries may exist even without bundles)
    has_items=1
    echo "  TCC Permissions:"
    local tcc_ids=()
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local bundle_id="${APP_BUNDLE_IDS[$idx]}"
        if [[ ! " ${tcc_ids[@]} " =~ " ${bundle_id} " ]]; then
            tcc_ids+=("$bundle_id")
        fi
    done
    if [[ ! " ${tcc_ids[@]} " =~ " com.muesli.app " ]]; then
        tcc_ids+=("com.muesli.app")
    fi
    echo "    - Screen Recording for: ${tcc_ids[*]}"
    echo "    - Microphone for: ${tcc_ids[*]}"
    echo "    - System Audio Capture for: ${tcc_ids[*]}"
    echo ""

    # UserDefaults
    echo "  UserDefaults:"
    local unique_ids=()
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local bundle_id="${APP_BUNDLE_IDS[$idx]}"
        if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
            unique_ids+=("$bundle_id")
            echo "    - $bundle_id"
        fi
    done
    if [ ${#unique_ids[@]} -eq 0 ]; then
        echo "    - com.muesli.app"
    fi
    echo ""
    
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
        echo "  Meeting Recordings:"
        echo "    - $RECORDINGS_COUNT recording(s) in $RECORDINGS_DIR"
        echo ""
    fi
    
    # Application Support
    if [ "$APP_SUPPORT_ACTION" = "delete" ]; then
        has_items=1
        if [ "$KEEP_MODELS" = true ]; then
            echo "  Application Support (keeping models):"
            echo "    - ~/Library/Application Support/Muesli/Logs/"
            echo "    - ~/Library/Application Support/Muesli/Exports/"
            if [ "$RECORDING_ACTION" != "keep" ] && [ "$RECORDING_ACTION" != "move" ]; then
                echo "    - ~/Library/Application Support/Muesli/Recordings/"
            fi
            echo ""
            echo "Will KEEP:"
            echo "  Downloaded Models:"
            echo "    - ~/Library/Application Support/Muesli/Models/"
        else
            echo "  Application Support:"
            if [ "$RECORDING_ACTION" = "move" ]; then
                echo "    - ~/Library/Application Support/Muesli/ (after moving recordings)"
            else
                echo "    - ~/Library/Application Support/Muesli/"
            fi
        fi
        echo ""
    elif [ "$APP_SUPPORT_ACTION" = "keep" ]; then
        echo "Will KEEP:"
        echo "  Application Support:"
        echo "    - ~/Library/Application Support/Muesli/"
        echo ""
    fi
    
    # DMG Volumes to eject
    if [ "$EJECT_DMGS" = true ] && [ ${#MOUNTED_DMG_VOLUMES[@]} -gt 0 ]; then
        has_items=1
        echo "Will EJECT:"
        echo "  Mounted DMG Volumes (${#MOUNTED_DMG_VOLUMES[@]}):"
        for vol in "${MOUNTED_DMG_VOLUMES[@]}"; do
            local vol_name=$(basename "$vol")
            echo "    - $vol_name"
        done
        echo ""
    fi
    
    # Launch Services unregistration
    local apps_to_unregister=0
    [ ${#SELECTED_BUNDLES[@]} -gt 0 ] && apps_to_unregister=$((apps_to_unregister + ${#SELECTED_BUNDLES[@]}))
    [ "$EJECT_DMGS" = true ] && apps_to_unregister=$((apps_to_unregister + ${#MOUNTED_DMG_APPS[@]}))
    [ "$DELETE_TRASH_APPS" = true ] && apps_to_unregister=$((apps_to_unregister + ${#TRASH_APPS[@]}))
    
    if [ $apps_to_unregister -gt 0 ]; then
        echo "Will UNREGISTER from Launch Services:"
        echo "  - $apps_to_unregister app(s) will be unregistered before deletion"
        echo ""
    fi
    
    if [ $has_items -eq 0 ]; then
        echo "No items selected for removal."
        echo ""
        return 1
    fi
    
    echo "═══════════════════════════════════════════════════════════════"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN: No changes will be made${NC}"
    else
        echo -e "${RED}WARNING: This action cannot be undone (except for moved recordings)${NC}"
    fi
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    return 0
}

confirm_uninstall() {
    # Auto-yes: skip confirmation
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi

    echo ""
    echo -e "Type ${RED}uninstall${NC} to confirm, or anything else to cancel:"
    echo ""
    read -p "> " response
    if [ "$response" = "uninstall" ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# EXECUTION FUNCTIONS
# ============================================================================

# Unregister a single app from Launch Services (targeted, not global reset)
unregister_from_launch_services() {
    local app_path="$1"
    
    if [ ! -x "$LSREGISTER" ]; then
        print_warning "lsregister not found, skipping Launch Services cleanup"
        return 1
    fi
    
    local app_name=$(basename "$app_path")
    
    # Unregister BEFORE deleting the app
    if [ "$DRY_RUN" = true ]; then
        log_action "unregister" "$app_path"
        echo -e "${YELLOW}[DRY RUN]${NC} Would unregister from Launch Services: $app_name"
    else
        if "$LSREGISTER" -u "$app_path" 2>/dev/null; then
            log_action "unregistered" "$app_path"
            print_success "Unregistered from Launch Services: $app_name"
        else
            # May fail if already unregistered or path doesn't exist in DB, not an error
            log_action "unregister_skipped" "$app_path"
            print_info "Could not unregister (may already be unregistered): $app_name"
        fi
    fi
}

# Unregister all discovered apps from Launch Services
unregister_all_apps() {
    print_info "Unregistering apps from Launch Services..."
    
    # Unregister selected app bundles (these are being deleted)
    for idx in "${SELECTED_BUNDLES[@]}"; do
        unregister_from_launch_services "${APP_BUNDLES[$idx]}"
    done
    
    # Unregister mounted DMG apps (if user chose to eject)
    if [ "$EJECT_DMGS" = true ]; then
        for app in "${MOUNTED_DMG_APPS[@]}"; do
            unregister_from_launch_services "$app"
        done
    fi
    
    # Unregister Trash apps (if user chose to delete them)
    if [ "$DELETE_TRASH_APPS" = true ]; then
        for app in "${TRASH_APPS[@]}"; do
            unregister_from_launch_services "$app"
        done
    fi
}

kill_muesli_processes() {
    print_info "Killing running Muesli processes..."
    
    local killed=0
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local app="${APP_BUNDLES[$idx]}"
        local app_name=$(basename "$app" .app)
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_kill" "$app_name"
            echo -e "${YELLOW}[DRY RUN]${NC} Would kill process: $app_name"
            killed=$((killed + 1))
        elif killall "$app_name" 2>/dev/null; then
            log_action "killed" "$app_name"
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
    
    if [ "$DRY_RUN" = true ]; then
        log_action "would_create_dir" "$dest_recordings"
        echo -e "${YELLOW}[DRY RUN]${NC} Would create: $dest_recordings"
    elif ! mkdir -p "$dest_recordings" 2>/dev/null; then
        print_error "Failed to create destination: $dest_recordings"
        return 1
    fi
    
    # Move all recording folders
    local moved=0
    local failed=0
    while IFS= read -r -d '' recording; do
        local recording_name=$(basename "$recording")
        if [ "$DRY_RUN" = true ]; then
            log_action "would_move" "$recording -> $dest_recordings/"
            echo -e "${YELLOW}[DRY RUN]${NC} Would move: $recording_name"
            moved=$((moved + 1))
        elif mv "$recording" "$dest_recordings/" 2>/dev/null; then
            log_action "moved" "$recording -> $dest_recordings/"
            moved=$((moved + 1))
        else
            log_action "move_failed" "$recording"
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

delete_recordings() {
    if [ ! -d "$RECORDINGS_DIR" ]; then
        print_info "Recordings directory not found"
        return 0
    fi

    print_info "Deleting recordings..."

    local deleted=0
    local failed=0
    while IFS= read -r -d '' recording; do
        local recording_name=$(basename "$recording")
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_recording" "$recording"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete recording: $recording_name"
            deleted=$((deleted + 1))
        elif rm -rf "$recording" 2>/dev/null; then
            log_action "deleted_recording" "$recording"
            deleted=$((deleted + 1))
        else
            log_action "delete_recording_failed" "$recording"
            print_error "Failed to delete: $recording_name"
            failed=$((failed + 1))
        fi
    done < <(find "$RECORDINGS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

    print_success "Deleted $deleted recording(s)"
    if [ $failed -gt 0 ]; then
        print_warning "$failed recording(s) failed to delete"
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
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete" "$app"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete: $app_name"
        elif rm -rf "$app" 2>/dev/null; then
            log_action "deleted" "$app"
            print_success "Deleted: $app_name"
        else
            log_action "delete_failed" "$app"
            print_error "Failed to delete: $app_name"
        fi
    done
}

delete_derived_data() {
    if [ ${#SELECTED_DERIVED_DATA[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Deleting DerivedData folders..."

    for idx in "${SELECTED_DERIVED_DATA[@]}"; do
        local folder="${DERIVED_DATA_FOLDERS[$idx]}"
        local folder_name=$(basename "$folder")
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete" "$folder"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete: $folder_name"
        elif rm -rf "$folder" 2>/dev/null; then
            log_action "deleted" "$folder"
            print_success "Deleted: $folder_name"
        else
            log_action "delete_failed" "$folder"
            print_error "Failed to delete: $folder_name"
        fi
    done
}

eject_mounted_dmgs() {
    if [ "$EJECT_DMGS" != true ] || [ ${#MOUNTED_DMG_VOLUMES[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Ejecting mounted DMG volumes..."
    
    # Get unique volumes
    local -a unique_volumes=()
    for vol in "${MOUNTED_DMG_VOLUMES[@]}"; do
        if [[ ! " ${unique_volumes[*]} " =~ " ${vol} " ]]; then
            unique_volumes+=("$vol")
        fi
    done
    
    for vol in "${unique_volumes[@]}"; do
        local vol_name=$(basename "$vol")
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_eject" "$vol"
            echo -e "${YELLOW}[DRY RUN]${NC} Would eject: $vol_name"
        else
            # Check if volume has open files (lsof)
            if lsof +D "$vol" &>/dev/null; then
                log_action "eject_blocked" "$vol"
                print_warning "Volume has open files: $vol_name"
                print_warning "Close any Finder windows or apps using this volume, then retry"
            else
                if diskutil eject "$vol" 2>/dev/null; then
                    log_action "ejected" "$vol"
                    print_success "Ejected: $vol_name"
                else
                    log_action "eject_failed" "$vol"
                    print_error "Failed to eject: $vol_name"
                fi
            fi
        fi
    done
}

delete_trash_apps() {
    if [ "$DELETE_TRASH_APPS" != true ] || [ ${#TRASH_APPS[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Deleting apps from Trash..."
    
    for app in "${TRASH_APPS[@]}"; do
        local app_name=$(basename "$app")
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_trash" "$app"
            echo -e "${YELLOW}[DRY RUN]${NC} Would permanently delete from Trash: $app_name"
        elif rm -rf "$app" 2>/dev/null; then
            log_action "deleted_trash" "$app"
            print_success "Permanently deleted from Trash: $app_name"
        else
            log_action "delete_trash_failed" "$app"
            print_error "Failed to delete from Trash: $app_name"
        fi
    done
}

delete_per_bundle_artifacts() {
    if [ "$CLEAN_PER_BUNDLE_ARTIFACTS" != true ]; then
        return 0
    fi
    
    print_info "Deleting per-bundle artifacts..."
    
    # Delete cache directories
    for dir in "${BUNDLE_CACHE_DIRS[@]}"; do
        local dir_name=$(basename "$dir")
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_cache" "$dir"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete cache: $dir_name"
        elif rm -rf "$dir" 2>/dev/null; then
            log_action "deleted_cache" "$dir"
            print_success "Deleted cache: $dir_name"
        else
            log_action "delete_cache_failed" "$dir"
            print_error "Failed to delete cache: $dir_name"
        fi
    done
    
    # Delete HTTP storage directories
    for dir in "${BUNDLE_HTTP_DIRS[@]}"; do
        local dir_name=$(basename "$dir")
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_http" "$dir"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete HTTP storage: $dir_name"
        elif rm -rf "$dir" 2>/dev/null; then
            log_action "deleted_http" "$dir"
            print_success "Deleted HTTP storage: $dir_name"
        else
            log_action "delete_http_failed" "$dir"
            print_error "Failed to delete HTTP storage: $dir_name"
        fi
    done
    
    # Delete preference files
    for file in "${BUNDLE_PREF_FILES[@]}"; do
        local file_name=$(basename "$file")
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_pref" "$file"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete preference: $file_name"
        elif rm -f "$file" 2>/dev/null; then
            log_action "deleted_pref" "$file"
            print_success "Deleted preference: $file_name"
        else
            log_action "delete_pref_failed" "$file"
            print_error "Failed to delete preference: $file_name"
        fi
    done
}

delete_project_build_dirs() {
    if [ ${#PROJECT_BUILD_DIRS[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Deleting project build directories..."
    
    for dir in "${PROJECT_BUILD_DIRS[@]}"; do
        local dir_name=$(basename "$dir")
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_project_build" "$dir"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete project build: $dir_name"
        elif rm -rf "$dir" 2>/dev/null; then
            log_action "deleted_project_build" "$dir"
            print_success "Deleted project build: $dir_name"
        else
            log_action "delete_project_build_failed" "$dir"
            print_error "Failed to delete project build: $dir_name"
        fi
    done
}

delete_login_items() {
    if [ ${#LOGIN_ITEMS[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Deleting Login Items..."
    
    for plist in "${LOGIN_ITEMS[@]}"; do
        local plist_name=$(basename "$plist")
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_login_item" "$plist"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete Login Item: $plist_name"
        elif rm -f "$plist" 2>/dev/null; then
            log_action "deleted_login_item" "$plist"
            print_success "Deleted Login Item: $plist_name"
        else
            log_action "delete_login_item_failed" "$plist"
            print_error "Failed to delete Login Item: $plist_name"
        fi
    done
}

reset_tcc_permissions() {
    print_info "Resetting TCC permissions..."

    # Get unique bundle IDs from selected bundles
    local unique_ids=()
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local bundle_id="${APP_BUNDLE_IDS[$idx]}"
        if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
            unique_ids+=("$bundle_id")
        fi
    done

    # Also include bundle IDs from per-bundle artifacts being cleaned
    if [ "$CLEAN_PER_BUNDLE_ARTIFACTS" = true ]; then
        for dir in "${BUNDLE_CACHE_DIRS[@]}"; do
            local bundle_id=$(basename "$dir")
            if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
                unique_ids+=("$bundle_id")
            fi
        done
    fi

    # Always include the default bundle ID — TCC entries may exist even if no app
    # bundles were found (e.g., app was already deleted but permissions remain)
    if [[ ! " ${unique_ids[@]} " =~ " com.muesli.app " ]]; then
        unique_ids+=("com.muesli.app")
    fi

    for bundle_id in "${unique_ids[@]}"; do
        if [ "$DRY_RUN" = true ]; then
            log_action "would_reset_tcc" "$bundle_id"
            echo -e "${YELLOW}[DRY RUN]${NC} Would reset TCC permissions for: $bundle_id"
        else
            # Reset all TCC services Muesli uses:
            #   ScreenCapture  — screen recording (ScreenCaptureKit)
            #   Microphone     — microphone access (AVAudioEngine)
            #   ListenEvent    — system audio capture (Core Audio taps / NSAudioCaptureUsageDescription)
            for svc in ScreenCapture Microphone ListenEvent; do
                if svc_output=$(tccutil reset "$svc" "$bundle_id" 2>&1); then
                    log_action "reset_tcc_$svc" "$bundle_id"
                    print_success "Reset $svc for: $bundle_id"
                else
                    log_action "reset_tcc_${svc}_failed" "$bundle_id: $svc_output"
                    print_warning "Could not reset $svc for: $bundle_id ($svc_output)"
                fi
            done
        fi
    done
}

delete_user_defaults() {
    print_info "Deleting UserDefaults..."
    
    # Get unique bundle IDs
    local unique_ids=()
    for idx in "${SELECTED_BUNDLES[@]}"; do
        local bundle_id="${APP_BUNDLE_IDS[$idx]}"
        if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
            unique_ids+=("$bundle_id")
        fi
    done

    # If no bundles were selected, fall back to known bundle IDs
    if [ ${#unique_ids[@]} -eq 0 ]; then
        # Prefer any discovered preference files
        for file in "${BUNDLE_PREF_FILES[@]}"; do
            local bundle_id=$(basename "$file" .plist)
            if [[ ! " ${unique_ids[@]} " =~ " ${bundle_id} " ]]; then
                unique_ids+=("$bundle_id")
            fi
        done
    fi

    # Final fallback to the default bundle ID
    if [ ${#unique_ids[@]} -eq 0 ]; then
        unique_ids=("com.muesli.app")
    fi
    
    for bundle_id in "${unique_ids[@]}"; do
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete_defaults" "$bundle_id"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete UserDefaults for: $bundle_id"
        elif defaults delete "$bundle_id" 2>/dev/null; then
            log_action "deleted_defaults" "$bundle_id"
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
    
    if [ "$KEEP_MODELS" = true ]; then
        # Delete everything EXCEPT the Models directory
        print_info "Deleting Application Support (keeping models)..."
        
        # Delete Logs directory
        if [ -d "$APP_SUPPORT_DIR/Logs" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_action "would_delete" "$APP_SUPPORT_DIR/Logs"
                echo -e "${YELLOW}[DRY RUN]${NC} Would delete: ~/Library/Application Support/Muesli/Logs"
            elif rm -rf "$APP_SUPPORT_DIR/Logs" 2>/dev/null; then
                log_action "deleted" "$APP_SUPPORT_DIR/Logs"
                print_success "Deleted: ~/Library/Application Support/Muesli/Logs"
            else
                print_warning "Could not delete Logs folder"
            fi
        fi
        
        # Delete Recordings directory (if not already moved/kept by user choice)
        if [ -d "$APP_SUPPORT_DIR/Recordings" ] && [ "$RECORDING_ACTION" != "keep" ] && [ "$RECORDING_ACTION" != "move" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_action "would_delete" "$APP_SUPPORT_DIR/Recordings"
                echo -e "${YELLOW}[DRY RUN]${NC} Would delete: ~/Library/Application Support/Muesli/Recordings"
            elif rm -rf "$APP_SUPPORT_DIR/Recordings" 2>/dev/null; then
                log_action "deleted" "$APP_SUPPORT_DIR/Recordings"
                print_success "Deleted: ~/Library/Application Support/Muesli/Recordings"
            else
                print_warning "Could not delete Recordings folder"
            fi
        fi
        
        # Delete Exports directory
        if [ -d "$APP_SUPPORT_DIR/Exports" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_action "would_delete" "$APP_SUPPORT_DIR/Exports"
                echo -e "${YELLOW}[DRY RUN]${NC} Would delete: ~/Library/Application Support/Muesli/Exports"
            elif rm -rf "$APP_SUPPORT_DIR/Exports" 2>/dev/null; then
                log_action "deleted" "$APP_SUPPORT_DIR/Exports"
                print_success "Deleted: ~/Library/Application Support/Muesli/Exports"
            else
                print_warning "Could not delete Exports folder"
            fi
        fi
        
        # Delete any other files in the root (but not subdirectories we want to keep)
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete root files in Application Support"
        else
            find "$APP_SUPPORT_DIR" -maxdepth 1 -type f -delete 2>/dev/null
        fi
        
        print_success "Kept: ~/Library/Application Support/Muesli/Models"
        return 0
    else
        # Delete everything
        print_info "Deleting Application Support folder..."
        
        if [ "$DRY_RUN" = true ]; then
            log_action "would_delete" "$APP_SUPPORT_DIR"
            echo -e "${YELLOW}[DRY RUN]${NC} Would delete: ~/Library/Application Support/Muesli"
        elif rm -rf "$APP_SUPPORT_DIR" 2>/dev/null; then
            log_action "deleted" "$APP_SUPPORT_DIR"
            print_success "Deleted: ~/Library/Application Support/Muesli"
        else
            print_error "Failed to delete Application Support folder"
            return 1
        fi
    fi
}

execute_uninstall() {
    if [ "$DRY_RUN" = true ]; then
        print_header "EXECUTING UNINSTALL (DRY RUN)"
        echo -e "${YELLOW}This is a DRY RUN - no changes will be made${NC}"
        echo ""
    else
        print_header "EXECUTING UNINSTALL"
    fi
    
    # Log start of uninstall
    log_action "uninstall_started" "$(date)"
    
    # Handle recordings first (move or delete as requested)
    if [ "$RECORDING_ACTION" = "move" ]; then
        move_recordings || print_warning "Recording move failed, continuing with uninstall..."
    elif [ "$RECORDING_ACTION" = "delete" ]; then
        delete_recordings
    fi
    
    # 1. Unregister apps from Launch Services BEFORE deleting them
    unregister_all_apps

    # 2. Kill running processes
    kill_muesli_processes

    # 3. Reset TCC permissions BEFORE deleting app bundles
    # On macOS 15+, tccutil may need the app bundle present to verify the
    # code signing identity. Resetting after deletion could silently fail.
    reset_tcc_permissions

    # 4. Delete app bundles (DerivedData, /Applications, ~/Applications)
    delete_app_bundles

    # 5. Delete Trash apps (if user confirmed)
    delete_trash_apps

    # 6. Eject mounted DMGs (if user confirmed)
    eject_mounted_dmgs

    # 7. Delete DerivedData folders
    delete_derived_data

    # 8. Delete project build directories
    delete_project_build_dirs

    # 9. Delete UserDefaults
    delete_user_defaults

    # 10. Delete per-bundle caches/HTTP storages/preferences
    delete_per_bundle_artifacts

    # 11. Delete Login Items
    delete_login_items

    # 12. Delete Application Support (unless keeping recordings)
    delete_application_support || print_warning "Application Support deletion failed, continuing..."
    
    # Log completion
    log_action "uninstall_completed" "$(date)"
    
    if [ "$DRY_RUN" = true ]; then
        print_header "DRY RUN COMPLETE"
        echo -e "${YELLOW}No changes were made. Review the output above.${NC}"
        echo ""
        echo "To perform the actual uninstall, run without --dry-run:"
        echo "  ./scripts/uninstall.sh"
        echo ""
        echo "Log file: $LOG_FILE"
    else
        print_header "UNINSTALL COMPLETE"
        
        if [ "$RECORDING_ACTION" = "move" ] && [ -n "$RECORDING_DESTINATION" ]; then
            print_info "Recordings saved to: $RECORDING_DESTINATION/Recordings"
        fi
        
        if [ "$KEEP_MODELS" = true ]; then
            print_success "Muesli has been uninstalled (models preserved)"
            echo ""
            echo "Models kept at:"
            echo "  - WhisperKit: ~/Library/Application Support/Muesli/Models/"
            echo "  - LLM models: ~/.cache/huggingface/hub/ (if present)"
            echo ""
            echo "On reinstall, Muesli will automatically detect these models."
        else
            print_success "Muesli has been uninstalled from your system"
        fi
        
        echo ""
        echo "You can now:"
        echo "  - Test a clean installation from DMG"
        echo "  - Build fresh from Xcode"
        echo "  - Test the onboarding flow"
        echo ""
        echo "Log file: $LOG_FILE"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        clear 2>/dev/null || true
    fi
    
    print_header "MUESLI UNINSTALLER"
    
    # Show dry run notice
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}═══ DRY RUN MODE ═══${NC}"
        echo "No changes will be made. This is a preview of what would be deleted."
        echo ""
    fi
    
    # Safety check
    check_not_root
    
    # Initialize log file
    echo "Muesli Uninstaller Log - $(date)" > "$LOG_FILE"
    echo "DRY_RUN=$DRY_RUN" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
    
    # =========================================================================
    # DISCOVERY PHASE
    # =========================================================================
    print_header "DISCOVERY PHASE"
    
    # Original discovery functions
    find_app_bundles
    find_user_applications_apps
    find_derived_data
    count_recordings
    
    # New discovery functions for comprehensive cleanup
    find_mounted_dmg_apps
    find_trash_apps
    find_login_items
    find_per_bundle_artifacts
    find_project_build_dirs
    
    # Check if anything was found
    local has_app_support=false
    if [ -d "$APP_SUPPORT_DIR" ]; then
        has_app_support=true
    fi
    
    local total_found=$((${#APP_BUNDLES[@]} + ${#DERIVED_DATA_FOLDERS[@]} + ${#MOUNTED_DMG_APPS[@]} + ${#TRASH_APPS[@]} + ${#BUNDLE_CACHE_DIRS[@]} + ${#BUNDLE_HTTP_DIRS[@]} + ${#BUNDLE_PREF_FILES[@]} + ${#PROJECT_BUILD_DIRS[@]} + ${#LOGIN_ITEMS[@]}))
    
    if [ $total_found -eq 0 ] && [ "$RECORDINGS_COUNT" -eq 0 ] && [ "$has_app_support" = false ]; then
        print_warning "No Muesli installations found"
        echo ""
        echo "Searched in:"
        echo "  - ~/Library/Developer/Xcode/DerivedData/"
        echo "  - <project>/DerivedData/ (local build folder)"
        echo "  - /Applications/"
        echo "  - ~/Applications/"
        echo "  - ~/.Trash/"
        echo "  - /Volumes/ (mounted DMGs)"
        echo "  - ~/Library/Application Support/Muesli/"
        echo "  - ~/Library/Caches/com.muesli.app*/"
        echo "  - ~/Library/HTTPStorages/com.muesli.app*/"
        echo "  - ~/Library/Preferences/com.muesli.app*.plist"
        echo "  - ~/Library/LaunchAgents/"
        echo ""
        exit $EXIT_SUCCESS
    fi
    
    # =========================================================================
    # INTERACTIVE SELECTION PHASE
    # =========================================================================
    
    # App bundle selection
    if [ ${#APP_BUNDLES[@]} -gt 0 ]; then
        interactive_select_bundles
    fi

    # DerivedData selection
    if [ ${#DERIVED_DATA_FOLDERS[@]} -gt 0 ]; then
        interactive_select_derived_data
    fi

    # Mounted DMG handling
    prompt_mounted_dmg_action
    
    # Trash apps handling (with permanent deletion warning)
    prompt_trash_deletion
    
    # Recording handling
    if [ "$RECORDINGS_COUNT" -gt 0 ]; then
        prompt_recording_action
    else
        RECORDING_ACTION="none"
    fi
    
    # Application Support handling (separate from recordings)
    prompt_app_support_action
    
    # Per-bundle artifacts handling
    prompt_per_bundle_artifacts
    
    # =========================================================================
    # SUMMARY AND CONFIRMATION
    # =========================================================================
    
    # Show summary and confirm
    if ! show_summary; then
        print_warning "Nothing selected to uninstall"
        exit $EXIT_CANCELLED
    fi
    
    if ! confirm_uninstall; then
        print_info "Uninstall cancelled by user"
        exit $EXIT_CANCELLED
    fi
    
    # =========================================================================
    # EXECUTION
    # =========================================================================
    
    # Execute uninstall
    execute_uninstall
    
    exit $EXIT_SUCCESS
}

# Run main
main
