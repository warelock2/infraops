# Release Script Workflow Guide

This guide outlines the process for managing versions and creating releases using the `build-release.sh` script. This script is the single, centralized tool for all versioning-related tasks.

---

## Theory of Operation

The `build-release.sh` script automates the entire process of creating a new release. Its primary responsibilities are:

1.  **Updating the Version:** It reads the current version from `_version.py` and calculates the next version based on the command-line options provided.
2.  **Committing the Change:** It creates a new Git commit containing the updated `_version.py` file.
3.  **Tagging the Release:** It creates an annotated Git tag pointing to the new version commit. This tag is the **single source of truth** for the release version.
4.  **Pushing to Remote:** It pushes the new commit and its corresponding tag to the remote repository (`origin`).

This push triggers all downstream CI/CD workflows, such as the GitHub Actions that build the `.deb` package and other release artifacts.

---

## Command-Line Options

The following options are available to control the script's behavior.

### Query Options

| Flag                          | Description                                                                     |
|-------------------------------|---------------------------------------------------------------------------------|
| `-c`, `--show-current-version` | Displays the application's version string as read directly from `_version.py`.  |
| `-v`, `--version`             | Displays verbose version information for the *script itself* (derived from git tag). |
| `--short-version`             | Displays only the version number for the *script itself* (derived from git tag). |

### Setup Options

| Flag                  | Description                                                                     |
|-----------------------|---------------------------------------------------------------------------------|
| `--install-bash-tab-completion`| Creates a file containing the bash tab completion script and provides installation instructions. |

**Important Note:** The generated completion script includes the absolute path to `build-release.sh`. If you move the `build-release.sh` script to a different location, you must re-run the `--install-bash-tab-completion` option from the new location and update the corresponding entry in your `~/.bashrc` file.

### Release Type (Choose one)

These options determine the new version number based on Semantic Versioning.

| Flag                  | Description                                                                     | Example (`1.2.3` ->) |
|-----------------------|---------------------------------------------------------------------------------|----------------------|
| `--major`             | Bumps the version for a major release (for incompatible API changes).           | `2.0.0`              |
| `--minor`             | Bumps the version for a minor release (for new, backward-compatible features).  | `1.3.0`              |
| `--patch`             | Bumps the version for a patch release (for backward-compatible bug fixes).      | `1.2.4`              |
| `--set-version <ver>` | Skips automatic incrementing and sets the version to the exact `<ver>` string.     | `1.2.3-special`      |

### Pre-Release Modifiers

These can be combined with `--major`, `--minor`, or `--patch`.

| Flag    | Description                                                                                                                              | Example (`1.2.3` ->)        |
|---------|------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------|
| `--rc`  | Marks the release as a "release candidate". If a `...-rc.N` tag exists for the target version, this increments `N` (e.g., to `...-rc.2`). | `1.3.0-rc.1` (with `--minor`) |
| `--dev` | Marks the release as a "development" build.                                                                                              | `1.3.0-dev` (with `--minor`)  |

### Workflow Control

| Flag          | Description                                                                                                                     |
|---------------|---------------------------------------------------------------------------------------------------------------------------------|
| `--dry-run`   | Shows all commands that would be executed and the new version number, but does not perform any actions. **Recommended for safety.** |
| `--no-push`   | Performs all local actions (updates `_version.py`, commits, and tags) but does not push to the remote repository.                   |
| `-m`, `--message <msg>` | Provides a custom commit message for the version bump commit. |

---

## Example Project Lifecycle

This section describes how the release script fits into a typical developer workflow from the very beginning of a project.

### Phase 1: Initial Development (The "0.x.y" Era)

You've just started your project. The code is experimental and not yet stable.

**1. First-Ever Release**
*   **Goal:** Get the first bundle of code released for internal testing.
*   **Thought:** "I have enough code for a first look. It's not stable, so I'll start at version `0.1.0`."
*   **Command:** `./build-release.sh --minor`
*   **Action:** The script creates `_version.py` with `__version__ = "0.1.0"`, commits it, and pushes the `v0.1.0` tag.

**2. Adding a Feature**
*   **Goal:** Release a significant new feature.
*   **Thought:** "I've added a major new component. Since we're pre-1.0.0, this warrants a minor version bump."
*   **Command:** `./build-release.sh --minor`
*   **Action:** The script reads `0.1.0`, updates the version to `0.2.0`, commits, and pushes the `v0.2.0` tag.

**3. Fixing a Bug**
*   **Goal:** Fix a small bug found in the `0.2.0` release.
*   **Thought:** "This is a quick bugfix, so it's just a patch."
*   **Command:** `./build-release.sh --patch`
*   **Action:** The script reads `0.2.0`, updates the version to `0.2.1`, commits, and pushes the `v0.2.1` tag.

### Phase 2: Preparing for the First Stable Release (The "1.0.0" Launch)

The project is maturing and the API is stabilizing.

**1. First Release Candidate**
*   **Goal:** Create a pre-release version for final testing.
*   **Thought:** "The API is stable. Let's put out a release candidate for the `1.0.0` launch."
*   **Command:** `./build-release.sh --major --rc`
*   **Action:** The script reads `0.2.1`, bumps the major to `1.0.0`, adds the `-rc.1` suffix, and pushes the `v1.0.0-rc.1` tag.

**2. Bug Found in RC**
*   **Goal:** Fix a bug found in the release candidate.
*   **Thought:** "A bug was found in rc.1. I've fixed it, so now I need a second release candidate."
*   **Command:** `./build-release.sh --rc`
*   **Action:** The script sees the base version is `1.0.0` and the latest tag is `v1.0.0-rc.1`. It automatically creates version `1.0.0-rc.2` and pushes the `v1.0.0-rc.2` tag.

**3. The Official Launch**
*   **Goal:** The RC is approved. Time for the official, stable release.
*   **Thought:** "rc.2 is solid. Let's make it official."
*   **Command:** `./build-release.sh --major`
*   **Action:** The script sees the latest version is an RC. It "graduates" the version by removing the suffix, setting the final version to `1.0.0`, and pushes the `v1.0.0` tag.

### Phase 3: Long-Term Maintenance

The project is now public and stable.

**1. Post-Launch Patch**
*   **Goal:** Fix a bug discovered by a user in the `1.0.0` release.
*   **Thought:** "This is a critical bug fix that doesn't break anything. I need to get a patch release out."
*   **Command:** `./build-release.sh --patch`
*   **Action:** The script updates the version to `1.0.1` and pushes the `v1.0.1` tag.

**2. Adding a New Feature**
*   **Goal:** Release a new, backward-compatible feature.
*   **Thought:** "This new feature is ready and won't break anyone's existing setup. It's a minor release."
*   **Command:** `./build-release.sh --minor`
*   **Action:** The script updates the version to `1.1.0` and pushes the `v1.1.0` tag.

---

## Initial Project Setup

If the `_version.py` file does not exist when the script is run, it will be automatically created.

*   The default version will be `0.1.0`.
*   This can be overridden on the first run with a flag, for example:
    *   `./build-release.sh --patch` will create version `0.0.1`.
    *   `./build-release.sh --set-version 1.0.0` will create version `1.0.0`.