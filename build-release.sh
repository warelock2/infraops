#!/bin/bash

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -eo pipefail

VERSION_FILE="_version.py"
GPL_NOTICE="This program is free software under the GPL v3. See LICENSE for details."
ZTHA_NOTICE="Zero Transaction History Alliance (TM)"

# --- Help Function ---
show_help() {
    cat << EOF
Usage: ./build-release.sh [OPTIONS]

A comprehensive release management tool for this project. It automates version
bumping, committing, tagging, and pushing releases.

If no options are provided, this help message is displayed.

Query Options:
  -c, --show-current-version  Displays the application's version from _version.py.
  -v, --version               Displays verbose version info for the script itself.
  --short-version             Displays only the version number for the script itself.
  -h, --help                  Displays this help message.

Setup:
  --install-bash-tab-completion Creates a file with the bash tab completion script and provides installation instructions.

Release Type (Choose one):
  --major                     Bumps the version for a major release (e.g., 1.2.3 -> 2.0.0).
  --minor                     Bumps the version for a minor release (e.g., 1.2.3 -> 1.3.0).
  --patch                     Bumps the version for a patch release (e.g., 1.2.3 -> 1.2.4).
  --set-version <ver>         Sets the version to the exact <ver> string.

Pre-Release Modifiers:
  --rc                        Marks the release as a "release candidate" (e.g., 1.3.0-rc.1).
  --dev                       Marks the release as a "development" build (e.g., 1.3.0-dev).

Workflow Control:
  --dry-run                   Shows all commands that would be executed, but does not perform any actions.
  --no-push                   Performs all local actions (commit, tag) but does not push to the remote.
  --remote <remote_name>      Specifies the Git remote to push to (e.g., 'origin').
  -m, --message <msg>         Provides a custom commit message for the version bump.

$GPL_NOTICE
EOF
}

# --- Completion Script Function ---
show_completion_script() {
    local SCRIPT_PATH
    local COMPLETION_SCRIPT_FILENAME="build_release_bashrc_tab_completion_function.sh"
    SCRIPT_PATH=$(realpath "$0")

    # Create the completion script file
    cat > "$COMPLETION_SCRIPT_FILENAME" << 'EOF'
# --- Cipher-Wallet Completion ---
_cipher-wallet_completions() {
    # COMP_WORDS is an array of words in the current command line.
    # COMP_CWORD is the index of the current word.
    local cur_word prev_word
    cur_word="${COMP_WORDS[COMP_CWORD]}"
    prev_word="${COMP_WORDS[COMP_CWORD-1]}"

    # List of all options for the script.
    local opts="--major --minor --patch --set-version --rc --dev --dry-run --no-push --message -m --show-current-version -c --version -v --short-version --help -h --install-bash-tab-completion --remote"

    # If the previous word is an option that takes an argument,
    # we don't offer further option completions.
    case "${prev_word}" in
        --set-version|--message|-m|--remote)
            return 0
            ;; 
    esac

    # Generate possible completions for the current word.
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur_word}") )
    return 0
}
EOF

    # This part is appended outside the heredoc so SCRIPT_PATH is expanded
    echo "complete -F _cipher-wallet_completions build-release.sh ./build-release.sh \"$SCRIPT_PATH\"" >> "$COMPLETION_SCRIPT_FILENAME"
    echo "# --- End Cipher-Wallet Completion ---" >> "$COMPLETION_SCRIPT_FILENAME"

    # Print instructions to the user
    info "Bash completion script created at:"
    info ""
    info "$COMPLETION_SCRIPT_FILENAME"
    info ""
    info "To install, open that file, copy its contents, and paste them at the end of your ~/.bashrc file."
    info "After pasting, run the following command to activate it for your current session:"
    info "source ~/.bashrc"
    info ""
    info "IMPORTANT: The completion script uses an absolute path. If you move the project directory, you must re-run this command and update your ~/.bashrc file."
}


# --- Utility Functions ---
info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
    exit 1
}

# --- Argument Parsing ---
BUMP_MODE=""
SET_VERSION=""
PRE_RELEASE=""
COMMIT_MSG=""
DRY_RUN=false
NO_PUSH=false
REMOTE_NAME=""

# If no arguments, show help and exit
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;; 
        -c|--show-current-version)
            if [ ! -f "$VERSION_FILE" ]; then
                error "$VERSION_FILE not found."
            fi
            grep '__version__' "$VERSION_FILE" | cut -d '"' -f 2
            exit 0
            ;; 
        -v|--version)
            VERSION_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "N/A")
            VERSION=${VERSION_TAG#v}
            echo "build-release.sh (Cipher-Wallet Build Script) version $VERSION"
            echo "$ZTHA_NOTICE"
            echo "$GPL_NOTICE"
            exit 0
            ;; 
        --short-version)
            VERSION_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "N/A")
            echo "${VERSION_TAG#v}"
            exit 0
            ;; 
        --install-bash-tab-completion)
            show_completion_script
            exit 0
            ;; 
        --major|--minor|--patch)
            if [ -n "$BUMP_MODE" ]; then
                error "Only one bump mode (--major, --minor, --patch) can be specified."
            fi
            BUMP_MODE=${1#--}
            shift
            ;; 
        --set-version)
            SET_VERSION="$2"
            shift 2
            ;; 
        --rc|--dev)
            PRE_RELEASE=${1#--}
            shift
            ;; 
        -m|--message)
            COMMIT_MSG="$2"
            shift 2
            ;; 
        --dry-run)
            DRY_RUN=true
            shift
            ;; 
        --no-push)
            NO_PUSH=true
            shift
            ;;
        --remote)
            REMOTE_NAME="$2"
            shift 2
            ;; 
        *)
            error "Unknown option: $1"
            ;; 
    esac
done

# --- Version Calculation ---
info "--- Calculating next version ---"
CURRENT_VERSION=""
if [ ! -f "$VERSION_FILE" ]; then
    info "$VERSION_FILE not found. Will create it."
    if [ "$BUMP_MODE" == "major" ]; then CURRENT_VERSION="0.0.0"; fi
    if [ "$BUMP_MODE" == "minor" ]; then CURRENT_VERSION="0.0.0"; fi
    if [ "$BUMP_MODE" == "patch" ]; then CURRENT_VERSION="0.0.0"; fi
    if [ -z "$BUMP_MODE" ] && [ -z "$SET_VERSION" ]; then CURRENT_VERSION="0.0.0"; BUMP_MODE="minor"; fi # Default initial
else
    CURRENT_VERSION=$(grep '__version__' "$VERSION_FILE" | cut -d '"' -f 2)
fi

info "Current version: $CURRENT_VERSION"

if [ -n "$SET_VERSION" ]; then
    NEW_VERSION="$SET_VERSION"
else
    # Parse version string: 1.2.3-rc.4 -> V_MAJOR=1, V_MINOR=2, V_PATCH=3, V_PRE_RELEASE=rc.4
    V_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
    V_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
    V_PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3 | cut -d- -f1)
    if [[ "$CURRENT_VERSION" == *"-"* ]]; then
        V_PRE_RELEASE=$(echo "$CURRENT_VERSION" | cut -d- -f2-)
    else
        V_PRE_RELEASE=""
    fi

    # If no bump mode is specified, but we are on an RC, graduate it
    if [ -z "$BUMP_MODE" ] && [ -n "$V_PRE_RELEASE" ] && [[ "$V_PRE_RELEASE" == "rc"* ]]; then
        info "Graduating RC to final release."
        NEW_VERSION="$V_MAJOR.$V_MINOR.$V_PATCH"
    else
        # Increment version parts
        case $BUMP_MODE in
            major)
                V_MAJOR=$((V_MAJOR + 1))
                V_MINOR=0
                V_PATCH=0
                ;; 
            minor)
                V_MINOR=$((V_MINOR + 1))
                V_PATCH=0
                ;; 
            patch)
                V_PATCH=$((V_PATCH + 1))
                ;; 
            *)
                # This case handles --rc on an existing version without a bump
                : 
                ;; 
        esac
        NEW_VERSION="$V_MAJOR.$V_MINOR.$V_PATCH"
    fi

    # Append pre-release identifiers
    if [ "$PRE_RELEASE" == "dev" ]; then
        NEW_VERSION="$NEW_VERSION-dev"
    elif [ "$PRE_RELEASE" == "rc" ]; then
        # Find next RC number
        BASE_VERSION="$V_MAJOR.$V_MINOR.$V_PATCH"
        LAST_RC=$(git tag --list "v${BASE_VERSION}-rc.*" | sort -V | tail -n 1)
        if [ -z "$LAST_RC" ]; then
            NEW_RC_NUM=1
        else
            LAST_RC_NUM=$(echo "$LAST_RC" | sed 's/.*-rc.//')
            NEW_RC_NUM=$((LAST_RC_NUM + 1))
        fi
        NEW_VERSION="$BASE_VERSION-rc.$NEW_RC_NUM"
    fi
fi

info "New version: $NEW_VERSION"

# --- Dry Run Check ---
if [ "$DRY_RUN" = true ]; then
    info "--- Preparing release (DRY RUN) ---"
    if [ -z "$COMMIT_MSG" ]; then
        COMMIT_MSG="Bump version to $NEW_VERSION"
    fi
    TAG_NAME="v$NEW_VERSION"
    TAG_MSG="Release $TAG_NAME"

    info "DRY RUN: The following actions would be taken:"
    echo "1. Update $VERSION_FILE to __version__ = \"$NEW_VERSION\""
    echo "2. git add \"$VERSION_FILE\""
    echo "3. git commit -m \"$COMMIT_MSG\""
    echo "4. git tag -a \"$TAG_NAME\" -m \"$TAG_MSG\""
    if [ "$NO_PUSH" = false ]; then
        echo "5. git push-all ${REMOTE_NAME}"
        echo "6. git push-all ${REMOTE_NAME} --tags"
    fi
    exit 0
fi

# --- Pre-flight Checks for Modifying Operations ---
info "--- Checking prerequisites for release ---"
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    error "Not a git repository."
fi

if ! git diff-index --quiet HEAD --; then
    error "Working directory is not clean. Please commit or stash your changes."
fi
info "Git working directory is clean."


# --- Execution ---
info "--- Creating release ---"

if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="Bump version to $NEW_VERSION"
fi

TAG_NAME="v$NEW_VERSION"
TAG_MSG="Release $TAG_NAME"

# Update/Create _version.py
info "Updating $VERSION_FILE to version $NEW_VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    cat > "$VERSION_FILE" << EOF
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# This file is automatically generated by the build script.
# Do not edit it manually.

__version__ = "$NEW_VERSION"
EOF
else
    sed -i "s/__version__ = .*/__version__ = \"$NEW_VERSION\"/" "$VERSION_FILE"
fi

# Git actions
info "Committing version bump..."
git add "$VERSION_FILE"
git commit -m "$COMMIT_MSG"

info "Tagging release..."
git tag -a "$TAG_NAME" -m "$TAG_MSG"

if [ "$NO_PUSH" = true ]; then
    info "Skipping push as per --no-push flag."
else
    info "Pushing commit and tags to remote..."
    git push-all ${REMOTE_NAME}
    git push-all ${REMOTE_NAME} --tags
fi

info ""
info "Build complete! Version $NEW_VERSION has been released."
info "Tag '$TAG_NAME' was created and pushed."
