#!/bin/bash
#
# update_feature_branch.sh
#
# Brings the newest Loop release (LoopKit/LoopWorkspace main) into the
# feature/therapy-settings-history branch, in all three repositories
# (LoopWorkspace, Loop, LoopKit). See docs/THERAPY_HISTORY_FEATURE.md.
#
# Usage, from the LoopWorkspace folder:
#   Scripts/update_feature_branch.sh          merge the newest Loop release
#   Scripts/update_feature_branch.sh --undo   throw away a merge that was not pushed
#
# Nothing reaches GitHub until you answer "y" to the push question at the end.

set -uo pipefail

BRANCH="feature/therapy-settings-history"
UPSTREAM_WORKSPACE="https://github.com/LoopKit/LoopWorkspace.git"
FEATURE_REPOS=(Loop LoopKit)
GIT="git -c core.commitGraph=false"

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$*"; }
ask()  { local answer; read -r -p "$1 [y/N] " answer; [[ "$answer" == y || "$answer" == Y ]]; }
STOPPED=0
stop() {
    STOPPED=1
    printf '\n\033[31mSTOPPED: %s\033[0m\n' "$1"
    shift
    for line in "$@"; do printf '%s\n' "$line" | sed 's/^/    /'; done
    printf '\nNothing was pushed to GitHub. To go back to how things were, run:\n    Scripts/update_feature_branch.sh --undo\n'
    exit 1
}

# Loop/Loop.xcconfig holds your personal Apple team id. It is never committed.
# During a merge it is set aside in .git/personal-Loop.xcconfig and put back
# afterwards (or by --undo, if the script stopped half way).
XCCONFIG_BACKUP="$ROOT/.git/personal-Loop.xcconfig"
save_xcconfig() {
    if [[ ! -f "$XCCONFIG_BACKUP" ]] && ! git -C Loop diff --quiet -- Loop.xcconfig 2>/dev/null; then
        cp Loop/Loop.xcconfig "$XCCONFIG_BACKUP" && git -C Loop checkout -q -- Loop.xcconfig
    fi
}
restore_xcconfig() {
    if [[ -f "$XCCONFIG_BACKUP" ]]; then
        cp "$XCCONFIG_BACKUP" Loop/Loop.xcconfig && rm "$XCCONFIG_BACKUP"
    fi
}
# Put it back on any normal exit, but not while a merge is half done.
trap '[[ $STOPPED == 1 ]] || restore_xcconfig' EXIT

# ---------------------------------------------------------------- --undo
if [[ "${1:-}" == "--undo" ]]; then
    bold "Undo: make all three repositories match GitHub ($BRANCH)"
    echo "This throws away local merges and commits that were not pushed."
    ask "Continue?" || exit 0
    save_xcconfig
    for repo in "$ROOT" "$ROOT/Loop" "$ROOT/LoopKit"; do
        git -C "$repo" merge --abort 2>/dev/null
        git -C "$repo" fetch -q origin
        git -C "$repo" checkout -q "$BRANCH" && git -C "$repo" reset -q --hard "origin/$BRANCH" \
            && ok "$(basename "$repo"): back to $(git -C "$repo" rev-parse --short HEAD)"
    done
    git submodule update -q --init --recursive
    for repo in "${FEATURE_REPOS[@]}"; do git -C "$repo" checkout -q "$BRANCH"; done
    ok "Done. Everything matches GitHub again."
    exit 0
fi

# ---------------------------------------------------------------- 1. checks
bold "1/6  Checking that everything is clean"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || git checkout -q "$BRANCH" \
    || stop "Could not switch LoopWorkspace to $BRANCH."
if [[ -n "$(git status --porcelain --untracked-files=no --ignore-submodules=dirty)" ]]; then
    git status --short --untracked-files=no --ignore-submodules=dirty
    stop "LoopWorkspace has unsaved changes (listed above)." \
         "If you don't need them: Scripts/update_feature_branch.sh --undo"
fi
for repo in "${FEATURE_REPOS[@]}"; do
    git -C "$repo" checkout -q "$BRANCH" 2>/dev/null || stop "Could not switch $repo to $BRANCH."
    changes="$(git -C "$repo" status --porcelain --untracked-files=no | grep -v ' Loop.xcconfig$')"
    [[ -z "$changes" ]] || stop "$repo has unsaved changes:" "$changes"
    git -C "$repo" remote get-url upstream >/dev/null 2>&1 \
        || git -C "$repo" remote add upstream "https://github.com/LoopKit/$repo.git"
done
ok "Clean."

# ---------------------------------------------------------------- push (step 6)
push_and_finish() {
    bold "6/6  Upload to GitHub"
    if ! ask "Push to your GitHub repositories now?"; then
        echo "    Not pushed. Run this script again later, or undo with --undo."
        exit 0
    fi
    for repo in "${FEATURE_REPOS[@]}"; do
        git -C "$repo" push -q origin "$BRANCH" || stop "Push of $repo failed. If it says 'authentication', run: gh auth login"
        ok "$repo pushed."
    done
    git push -q origin "$BRANCH" || stop "Push of LoopWorkspace failed. If it says 'authentication', run: gh auth login"
    ok "LoopWorkspace pushed."

    cat <<EOF

Done. Now build it:
  1. github.com/nadavv/LoopWorkspace -> Actions -> "4. Build Loop" -> Run workflow
  2. "Use workflow from": $BRANCH -> Run workflow (takes about an hour)
  3. TestFlight -> Loop -> install the new build (check it says your branch in Actions)
  4. Check Settings -> History still shows your old entries.
EOF
}

# ---------------------------------------------------------------- 2. download
bold "2/6  Downloading the newest Loop release and your branch from GitHub"
git fetch -q origin || stop "Could not reach GitHub. Check the internet connection, or run: gh auth login"
git merge -q --ff-only "origin/$BRANCH" 2>/dev/null || stop "Your local LoopWorkspace and GitHub differ; run --undo first."
git fetch -q "$UPSTREAM_WORKSPACE" main || stop "Could not download LoopKit/LoopWorkspace."
NEW="$(git rev-parse FETCH_HEAD)"
CURRENT_VERSION="$(sed -n 's/^LOOP_MARKETING_VERSION = //p' VersionOverride.xcconfig)"
NEW_VERSION="$(git show "$NEW:VersionOverride.xcconfig" | sed -n 's/^LOOP_MARKETING_VERSION = //p')"
echo "    Your feature build is on Loop $CURRENT_VERSION. Newest Loop release: $NEW_VERSION."
if git merge-base --is-ancestor "$NEW" HEAD; then
    if [[ -n "$(git rev-list "origin/$BRANCH..HEAD")" ]]; then
        ok "Already merged, but not pushed to GitHub yet."
        push_and_finish
    else
        ok "Already up to date. Nothing to do."
    fi
    exit 0
fi
ask "Merge Loop $NEW_VERSION into the feature branch? (local only, nothing is pushed yet)" || exit 0

# ---------------------------------------------------------------- 3. Loop + LoopKit
save_xcconfig
bold "3/6  Merging the new release into Loop and LoopKit (where the feature lives)"
for repo in "${FEATURE_REPOS[@]}"; do
    target="$(git ls-tree "$NEW" "$repo" | awk '{print $3}')"
    git -C "$repo" fetch -q origin && git -C "$repo" merge -q --ff-only "origin/$BRANCH" 2>/dev/null \
        || stop "Your local $repo and GitHub differ; run --undo first."
    git -C "$repo" fetch -q upstream
    git -C "$repo" cat-file -e "$target^{commit}" 2>/dev/null || git -C "$repo" fetch -q upstream "$target" \
        || stop "Could not download $repo commit $target."
    if git -C "$repo" merge-base --is-ancestor "$target" HEAD; then
        ok "$repo: already contains it."
        continue
    fi
    if ! $GIT -C "$repo" merge -q --no-edit -m "Merge Loop $NEW_VERSION into $BRANCH" "$target"; then
        conflicts="$(git -C "$repo" diff --name-only --diff-filter=U)"
        stop "$repo: the new Loop release changed the same lines as the feature (a 'merge conflict')." \
             "Files:" "$conflicts" \
             "" \
             "This needs someone who can read Swift (see the guide, 'If the script stops')." \
             "Until then: keep using the feature build you have, or the regular Loop build."
    fi
    ok "$repo: merged."
done

# ---------------------------------------------------------------- 4. LoopWorkspace
bold "4/6  Merging the new release into LoopWorkspace"
$GIT merge -q --no-commit --no-ff "$NEW" >/dev/null 2>&1
git rev-parse -q --verify MERGE_HEAD >/dev/null || stop "LoopWorkspace: git could not start the merge."
git add "${FEATURE_REPOS[@]}"   # point at the merged Loop and LoopKit from step 3
conflicts="$(git diff --name-only --diff-filter=U)"
if [[ -n "$conflicts" ]]; then
    stop "LoopWorkspace: the new release changed the same lines as your setup:" "$conflicts" \
         "" \
         "Usually this is .github/workflows/build_loop.yml or .gitmodules. Keep LoopKit's new" \
         "version of the file and re-add your two small changes (see the guide)."
fi
$GIT commit -q --no-edit -m "Merge Loop $NEW_VERSION into $BRANCH" || stop "Could not create the merge commit."
git submodule update -q --init --recursive || stop "Could not update the other parts of Loop (submodules)."
for repo in "${FEATURE_REPOS[@]}"; do git -C "$repo" checkout -q "$BRANCH"; done
ok "Merged. Your build is now Loop $NEW_VERSION + therapy settings history (local only)."

# ---------------------------------------------------------------- 5. tests
bold "5/6  Tests (optional, needs Xcode, about 5-10 minutes)"
if ask "Run the therapy history tests in the simulator?"; then
    sim="$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')"
    [[ -n "$sim" ]] || stop "No iPhone simulator found. Open Xcode once, or skip the tests."
    log="$(mktemp -t loop-history-tests)"
    echo "    Running... (full log: $log)"
    if xcodebuild test -project LoopKit/LoopKit.xcodeproj -scheme Shared -destination "id=$sim" \
        -only-testing:LoopKitTests/TherapySettingHistoryFilterTests \
        -only-testing:LoopKitTests/TherapySettingsHistoryStoreTests \
        -only-testing:LoopKitTests/TherapyScheduleDiffTests \
        -only-testing:LoopKitTests/InsulinSensitivityHistoryUnitTests >"$log" 2>&1; then
        ok "$(grep -E 'Executed [0-9]+ tests' "$log" | tail -1 | sed 's/^ *//')"
    else
        grep -E 'error:|failed' "$log" | head -20
        stop "Tests failed (above). Don't push this; the feature needs fixing for Loop $NEW_VERSION."
    fi
else
    echo "    Skipped. The GitHub build in step 6 still checks that everything compiles."
fi
push_and_finish
