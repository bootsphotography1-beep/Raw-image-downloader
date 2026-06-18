#!/bin/bash
# setup.sh — Mac-side one-shot to create the GitHub repo and push RawDeck.
# Run this from inside the rawdeck/ directory on your MacBook.
#
# Usage: ./setup.sh
# Prereqs (verified below):
#   - Git installed (`xcode-select --install` or `brew install git`)
#   - GitHub CLI installed (`brew install gh`) and authenticated (`gh auth login`)
#   - git user.name and user.email configured

set -e  # exit on any error

REPO_NAME="Raw-image-downloader"
GITHUB_USER="bootsphotography1-beep"
REPO_DESC="Fast, minimal RAW culling app for macOS — drag, rate, send to Pixelmator Pro."
REPO_VISIBILITY="public"  # change to "private" if you want it hidden

echo "============================================"
echo "  RawDeck — GitHub setup"
echo "============================================"
echo "  Target: $GITHUB_USER/$REPO_NAME"
echo "  Visibility: $REPO_VISIBILITY"
echo ""

# 1. Tool checks (do these FIRST so the user gets a clear error
#    if a tool is missing, before any state is changed).
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI ('gh') is not installed."
    echo "  Install with:  brew install gh"
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI is not authenticated."
    echo "  Authenticate with:  gh auth login"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is not installed."
    echo "  Install with:  xcode-select --install"
    exit 1
fi

if ! git config user.email >/dev/null 2>&1 || ! git config user.name >/dev/null 2>&1; then
    echo "ERROR: git user.name and/or user.email are not configured."
    echo "  Fix with:"
    echo "    git config --global user.name  \"Your Name\""
    echo "    git config --global user.email \"you@example.com\""
    exit 1
fi

# 2. Check we're in the right directory
if [ ! -f "RawDeck.xcodeproj/project.pbxproj" ]; then
    echo "ERROR: RawDeck.xcodeproj not found."
    echo "Run this script from inside the rawdeck/ folder."
    echo "  cd rawdeck"
    echo "  ./setup.sh"
    exit 1
fi

# 3. Initialize git if not already a repo
if [ ! -d ".git" ]; then
    echo "→ Initializing git repo..."
    git init
    git checkout -b main 2>/dev/null || git branch -M main
fi

# 4. Add and commit everything
echo "→ Staging files..."
git add .

if git diff --cached --quiet; then
    echo "→ No new changes to commit."
else
    echo "→ Creating initial commit..."
    git commit -m "Initial commit: RawDeck v1.0

- Drag-and-drop RAW culling (CR3, ARW, NEF, RAF, DNG, etc.)
- 5-star rating + reject flag
- Open in Pixelmator Pro
- Trash to macOS Trash (recoverable)
- Keyboard shortcuts: 1-5 rate, X reject, Delete trash, Cmd+O import, Cmd+Shift+O Pixelmator"
fi

# 5. Create the GitHub repo and push
echo "→ Creating GitHub repo $GITHUB_USER/$REPO_NAME..."
if gh repo view "$GITHUB_USER/$REPO_NAME" >/dev/null 2>&1; then
    echo "  → Repo already exists on GitHub. Skipping create."
    git remote add origin "https://github.com/$GITHUB_USER/$REPO_NAME.git" 2>/dev/null || true
else
    gh repo create "$GITHUB_USER/$REPO_NAME" \
        --"$REPO_VISIBILITY" \
        --description "$REPO_DESC" \
        --source=. \
        --remote=origin \
        --push
fi

# 6. Push to main
echo "→ Pushing to main..."
git push -u origin main

echo ""
echo "============================================"
echo "  ✓ Done!"
echo "============================================"
echo "  Your repo:  https://github.com/$GITHUB_USER/$REPO_NAME"
echo ""
echo "  Next steps:"
echo "  1. open RawDeck.xcodeproj  (open in Xcode)"
echo "  2. Press Cmd+R to build and run"
echo "  3. Drag a folder of CR3 (or other RAW) photos into the window"
echo "  4. Press 1-5 to rate, X to reject, Cmd+Shift+O to send to Pixelmator Pro"
echo ""
