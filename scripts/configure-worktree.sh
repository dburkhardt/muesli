#!/bin/bash
# Automatic worktree configuration script
# Reads .cursorworktrees.json and applies app identity configuration

set -e

# Detect worktree suffix from current directory
WORKTREE_PATH=$(pwd)
SUFFIX=$(basename "$WORKTREE_PATH")

echo "🔍 Detected worktree suffix: $SUFFIX"

# Check if .cursorworktrees.json exists
CONFIG_FILE="$WORKTREE_PATH/.cursorworktrees.json"
if [ ! -f "$CONFIG_FILE" ]; then
    # Try parent directory (git root)
    CONFIG_FILE=$(git rev-parse --show-toplevel 2>/dev/null)/.cursorworktrees.json
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: .cursorworktrees.json not found"
    echo "   Please create it or run manual configuration"
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
    echo "  2. Commit: git add $PROJECT_FILE && git commit -m 'Configure worktree app identity: $SUFFIX'"
    echo "  3. Push: git push -u origin \$(git branch --show-current)"
fi
