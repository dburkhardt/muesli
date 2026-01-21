#!/bin/bash
# Automatic worktree configuration script
# Checks for per-branch .worktree-config.json first, then falls back to .cursorworktrees.json

set -e

# Detect worktree suffix from current directory
WORKTREE_PATH=$(pwd)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$WORKTREE_PATH")

echo "🔍 Detected working directory: $WORKTREE_PATH"

# Priority 1: Check for per-branch indicator file (.worktree-config.json)
BRANCH_CONFIG="$WORKTREE_PATH/.worktree-config.json"
if [ -f "$BRANCH_CONFIG" ]; then
    echo "✓ Found per-branch indicator file: $BRANCH_CONFIG"
    
    # Extract configuration using jq or grep
    if command -v jq &> /dev/null; then
        NEEDS_WORKTREE=$(jq -r ".needsWorktree // false" "$BRANCH_CONFIG")
        
        if [ "$NEEDS_WORKTREE" != "true" ]; then
            echo "⚠️  This branch does not need worktree isolation (needsWorktree: $NEEDS_WORKTREE)"
            echo "   No configuration changes needed. Exiting."
            exit 0
        fi
        
        SUFFIX=$(jq -r ".suffix // empty" "$BRANCH_CONFIG")
        BUNDLE_ID=$(jq -r ".bundleId // empty" "$BRANCH_CONFIG")
        PRODUCT_NAME=$(jq -r ".productName // empty" "$BRANCH_CONFIG")
        REASON=$(jq -r ".reason // \"not specified\"" "$BRANCH_CONFIG")
        
        echo "📋 Configuration from branch indicator:"
        echo "   Suffix: $SUFFIX"
        echo "   Bundle ID: $BUNDLE_ID"
        echo "   Product Name: $PRODUCT_NAME"
        echo "   Reason: $REASON"
    else
        echo "⚠️  jq not found, cannot parse .worktree-config.json"
        echo "   Install jq with: brew install jq"
        exit 1
    fi
    
    if [ -z "$SUFFIX" ] || [ -z "$BUNDLE_ID" ] || [ -z "$PRODUCT_NAME" ]; then
        echo "❌ Error: Invalid configuration in $BRANCH_CONFIG"
        echo "   Required fields: suffix, bundleId, productName"
        exit 1
    fi
    
# Priority 2: Fall back to legacy .cursorworktrees.json (backward compatibility)
else
    SUFFIX=$(basename "$WORKTREE_PATH")
    echo "⚠️  No per-branch indicator file found (.worktree-config.json)"
    echo "   Falling back to legacy .cursorworktrees.json lookup"
    echo "   Detected suffix from directory name: $SUFFIX"
    
    # Check if .cursorworktrees.json exists
    CONFIG_FILE="$GIT_ROOT/.cursorworktrees.json"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ""
        echo "❌ Error: No worktree configuration found"
        echo ""
        echo "Options:"
        echo "  1. Create per-branch indicator: .worktree-config.json (recommended)"
        echo "     See .worktree-config.json.template for example"
        echo ""
        echo "  2. Add entry to legacy .cursorworktrees.json at repo root"
        echo ""
        echo "If this branch doesn't need worktree isolation, no action needed."
        exit 1
    fi
    
    echo "📄 Reading configuration from: $CONFIG_FILE"
    
    # Extract configuration using jq or grep
    if command -v jq &> /dev/null; then
        BUNDLE_ID=$(jq -r ".worktrees.\"$SUFFIX\".bundleId // empty" "$CONFIG_FILE")
        PRODUCT_NAME=$(jq -r ".worktrees.\"$SUFFIX\".productName // empty" "$CONFIG_FILE")
    else
        # Fallback to pattern matching
        BUNDLE_ID="com.muesli.app.$SUFFIX"
        PRODUCT_NAME="Muesli-$SUFFIX"
    fi
    
    if [ -z "$BUNDLE_ID" ]; then
        echo "⚠️  No configuration found for suffix '$SUFFIX'"
        echo "   Using defaults: $BUNDLE_ID, $PRODUCT_NAME"
    fi
fi

echo ""
echo "🔧 Applying configuration:"
echo "   Bundle ID: $BUNDLE_ID"
echo "   Product Name: $PRODUCT_NAME"

# Apply replacements to project file
PROJECT_FILE="Muesli.xcodeproj/project.pbxproj"

if [ ! -f "$PROJECT_FILE" ]; then
    echo "❌ Error: $PROJECT_FILE not found"
    exit 1
fi

# Backup original
cp "$PROJECT_FILE" "$PROJECT_FILE.backup"

# Replace bundle ID
sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = com\.muesli\.app;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;/g" "$PROJECT_FILE"

# Replace product name
sed -i '' "s/PRODUCT_NAME = \"\$(TARGET_NAME)\";/PRODUCT_NAME = \"$PRODUCT_NAME\";/g" "$PROJECT_FILE"

# Replace TCC reset script bundle IDs
sed -i '' "s/tccutil reset ScreenCapture com\.muesli\.app$/tccutil reset ScreenCapture $BUNDLE_ID/g" "$PROJECT_FILE"
sed -i '' "s/tccutil reset Microphone com\.muesli\.app$/tccutil reset Microphone $BUNDLE_ID/g" "$PROJECT_FILE"
sed -i '' "s/defaults delete com\.muesli\.app$/defaults delete $BUNDLE_ID/g" "$PROJECT_FILE"

# Verify changes
if git diff --quiet "$PROJECT_FILE"; then
    echo "⚠️  No changes made - configuration may already be applied"
    rm "$PROJECT_FILE.backup"
else
    echo "✅ Configuration applied successfully"
    echo ""
    echo "📊 Changes made:"
    git diff "$PROJECT_FILE" | head -20
    echo ""
    echo "💾 Backup saved to: $PROJECT_FILE.backup"
    echo ""
    echo "Next steps:"
    echo "  1. Review changes: git diff $PROJECT_FILE"
    if [ -f "$BRANCH_CONFIG" ]; then
        echo "  2. Commit: git add .worktree-config.json $PROJECT_FILE && git commit -m 'Configure worktree isolation for branch'"
    else
        echo "  2. Commit: git add $PROJECT_FILE && git commit -m 'Configure worktree app identity: $SUFFIX'"
    fi
    echo "  3. Push: git push -u origin \$(git branch --show-current)"
fi
