#!/usr/bin/env bash
# ==============================================================================
#  push_to_github.sh
#  Production-ready script: initialise git, write .gitignore, and push an iOS
#  project to a remote GitHub repository.
#
#  Usage:
#    chmod +x push_to_github.sh
#    ./push_to_github.sh
# ==============================================================================

set -euo pipefail   # -e exit on error  -u unset vars are errors  -o pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶  $*${RESET}"; }

REMOTE_URL="https://github.com/MasharipovShahzod/Counter-for-IOS.git"
COMMIT_MSG="Initial commit: Production-ready iOS Fitness tracking core with Vision Framework, CryptoKit architecture, and local anti-cheat systems"
BRANCH="main"

# ==============================================================================
# STEP 1 — Validate that we are inside an iOS project directory
# ==============================================================================
step "STEP 1 — Directory validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
info "Working directory: $SCRIPT_DIR"

if ! ls ./*.xcodeproj 2>/dev/null | grep -q . && \
   ! ls ./*.xcworkspace 2>/dev/null | grep -q .; then
    error "No .xcodeproj or .xcworkspace found in: $SCRIPT_DIR"
    error "Run this script from the root of your iOS project."
    exit 1
fi
success "iOS project detected."

# ==============================================================================
# STEP 2 — Write a production-grade iOS .gitignore
# ==============================================================================
step "STEP 2 — Generating .gitignore"

cat > .gitignore << 'GITIGNORE'
# ── Xcode ─────────────────────────────────────────────────────────────────────
build/
*.pbxuser
!default.pbxuser
*.mode1v3
!default.mode1v3
*.mode2v3
!default.mode2v3
*.perspectivev3
!default.perspectivev3
xcuserdata/
*.xccheckout
*.moved-aside
DerivedData/
*.hmap
*.ipa
*.xcuserstate
*.xcscmblueprint

# Xcode Workspace user data (but keep the workspace file itself)
*.xcworkspace/xcuserdata/

# ── Swift Package Manager ─────────────────────────────────────────────────────
.build/
.swiftpm/
*.resolved
# Keep Package.resolved if you want reproducible dependency versions:
# !Package.resolved

# ── CocoaPods ─────────────────────────────────────────────────────────────────
Pods/
*.xcworkspace
# Uncomment the next line if you DO commit the Podfile.lock:
# !Podfile.lock

# ── Carthage ──────────────────────────────────────────────────────────────────
Carthage/Build/
Carthage/Checkouts/

# ── Fastlane ──────────────────────────────────────────────────────────────────
fastlane/report.xml
fastlane/Preview.html
fastlane/screenshots/**/*.png
fastlane/test_output/

# ── macOS system files ────────────────────────────────────────────────────────
.DS_Store
.DS_Store?
._*
.Spotlight-V8
.Trashes
Icon?
Thumbs.db

# ── Sensitive / secret files ──────────────────────────────────────────────────
*.p12
*.cer
*.mobileprovision
AuthKey_*.p8
GoogleService-Info.plist
Secrets.swift
secrets.json
*.env
.env.*
Config/Production.xcconfig
Config/Staging.xcconfig

# ── Testing artefacts ─────────────────────────────────────────────────────────
*.gcno
*.gcda
coverage/

# ── Playgrounds ───────────────────────────────────────────────────────────────
timeline.xctimeline
playground.xcworkspace

# ── Miscellaneous ─────────────────────────────────────────────────────────────
*.log
*.tmp
*.bak
.sandbox/
GITIGNORE

success ".gitignore written."

# ==============================================================================
# STEP 3 — Git initialisation & configuration
# ==============================================================================
step "STEP 3 — Git initialisation"

if [ ! -d ".git" ]; then
    git init
    success "Git repository initialised."
else
    warn "Git already initialised — skipping git init."
fi

# Force the default branch to 'main' regardless of global git config.
git checkout -qB "$BRANCH" 2>/dev/null || git checkout -q "$BRANCH" 2>/dev/null || true
git symbolic-ref HEAD "refs/heads/$BRANCH"
success "Default branch set to '$BRANCH'."

# ── Remote URL ────────────────────────────────────────────────────────────────
if git remote get-url origin &>/dev/null; then
    CURRENT_REMOTE="$(git remote get-url origin)"
    if [ "$CURRENT_REMOTE" != "$REMOTE_URL" ]; then
        warn "Remote 'origin' exists with a different URL:"
        warn "  current : $CURRENT_REMOTE"
        warn "  updating to: $REMOTE_URL"
        git remote set-url origin "$REMOTE_URL"
    else
        info "Remote 'origin' already points to the correct URL."
    fi
else
    git remote add origin "$REMOTE_URL"
    success "Remote 'origin' added: $REMOTE_URL"
fi

# ==============================================================================
# STEP 4 — Stage all files and commit
# ==============================================================================
step "STEP 4 — Staging and committing"

git add .

# Only create a commit if there is something staged.
if git diff --cached --quiet; then
    warn "Nothing to commit — working tree is clean."
else
    git commit -m "$COMMIT_MSG"
    success "Commit created."
fi

# ==============================================================================
# STEP 5 — Push to remote with error handling
# ==============================================================================
step "STEP 5 — Pushing to GitHub"

info "Pushing branch '$BRANCH' → $REMOTE_URL"

push_output="$(git push -u origin "$BRANCH" 2>&1)" && push_exit=0 || push_exit=$?

if [ $push_exit -eq 0 ]; then
    echo "$push_output"
    echo ""
    success "Push successful! 🎉"
    info  "Repository live at: https://github.com/MasharipovShahzod/Counter-for-IOS"
else
    echo "$push_output"
    echo ""
    error "Push failed (exit code $push_exit)."
    echo ""

    # ── Diagnose common authentication failures ────────────────────────────
    if echo "$push_output" | grep -qiE "authentication failed|could not read|403|invalid username|remote: Support"; then
        echo -e "${YELLOW}──────────────────────────────────────────────────────${RESET}"
        echo -e "${BOLD}Authentication failure detected. How to fix:${RESET}"
        echo ""
        echo -e "${BOLD}Option A — Personal Access Token (HTTPS, recommended):${RESET}"
        echo "  1. Go to GitHub → Settings → Developer settings"
        echo "     → Personal access tokens → Fine-grained tokens → Generate new token"
        echo "  2. Grant: Contents (read & write), Metadata (read)"
        echo "  3. Re-run the push using the token as your password:"
        echo "       git push https://<YOUR_USERNAME>:<YOUR_TOKEN>@github.com/MasharipovShahzod/Counter-for-IOS.git main"
        echo ""
        echo -e "${BOLD}Option B — SSH key (zero-password workflow):${RESET}"
        echo "  1. Generate a key (if you don't have one):"
        echo "       ssh-keygen -t ed25519 -C 'your@email.com'"
        echo "  2. Add the public key to GitHub → Settings → SSH and GPG keys"
        echo "  3. Switch the remote to SSH:"
        echo "       git remote set-url origin git@github.com:MasharipovShahzod/Counter-for-IOS.git"
        echo "  4. Re-run:  git push -u origin main"
        echo -e "${YELLOW}──────────────────────────────────────────────────────${RESET}"
    fi

    # ── Repository does not exist on GitHub ───────────────────────────────
    if echo "$push_output" | grep -qiE "repository not found|does not exist|404"; then
        echo -e "${YELLOW}──────────────────────────────────────────────────────${RESET}"
        echo -e "${BOLD}Remote repository not found. How to fix:${RESET}"
        echo "  1. Go to https://github.com/new"
        echo "  2. Create a repo named exactly: Counter-for-IOS"
        echo "  3. Do NOT initialise it with a README — keep it empty."
        echo "  4. Re-run this script."
        echo -e "${YELLOW}──────────────────────────────────────────────────────${RESET}"
    fi

    exit $push_exit
fi
