# Therapy settings history build: maintenance guide

This branch is regular Loop plus one feature: a history of every therapy
settings change. This guide covers keeping that build current and working.

## The setup in one minute

| | Feature build | Regular Loop (the fallback) |
|---|---|---|
| Branch in nadavv/LoopWorkspace | `feature/therapy-settings-history` | `main` |
| Gets new Loop versions | **only when the script below is run** | automatically |
| Gets rebuilt | **only when "Run workflow" is pressed** | automatically, once a month |

Both are builds of the same app in TestFlight. TestFlight auto-update is **off**,
so the phone only changes when a build is installed by hand. That matters: the
monthly regular builds also land in TestFlight and must not replace the
feature build by accident.

Nothing below needs Claude or any AI, unless the script says **merge conflict**.

## The two things that can go wrong, and the safety net

1. **The build expires.** TestFlight builds stop opening after 90 days, and the
   feature build is never rebuilt automatically. → Rebuild every ~2 months (below). Put a
   repeating reminder in the calendar.
2. **Loop releases a new version** (sometimes an important fix). → Run the update
   script (below) soon after.

**Safety net:** a fresh regular Loop build is always in TestFlight, because `main`
rebuilds itself monthly. If the feature build ever breaks, expires, or can't be updated,
install the newest regular build. Settings, pump and CGM carry over, because it's
the same app. The history file stays on the phone; it just stops recording until
the feature build is back.

## Every ~2 months: rebuild

1. github.com/nadavv/LoopWorkspace → **Actions** → **4. Build Loop** → **Run workflow**
2. "Use workflow from": **feature/therapy-settings-history** → **Run workflow** (about an hour)
3. TestFlight → Loop → install the newest build. Regular and feature builds share one
   build numbering, so the newest number might be a *regular* build. In Actions,
   each run's title shows the branch it built: use the build from the run titled
   `Build Loop (feature/therapy-settings-history)`.
4. Open Loop and check Settings → History still shows the old entries.

## When a new Loop version comes out

On the Mac, in Terminal:

```
cd ~/xcode/Loop/LoopWorkspace
Scripts/update_feature_branch.sh
```

It shows the current version and the newest one, then asks three questions
(merge? run tests? push?). Answer `y` to all three. Nothing reaches GitHub
before the last `y`. Then rebuild as above.

To back out of anything the script did locally (before pushing):
`Scripts/update_feature_branch.sh --undo`

**Before relying on a new version**, give it a day while watching that Loop
loops normally and that History looks right. If anything is off, go back via
TestFlight → Loop → Previous Builds, or use the safety net.

**New Mac / folder gone?** First `brew install gh` and `gh auth login`, then:

```
git clone --recurse-submodules -b feature/therapy-settings-history https://github.com/nadavv/LoopWorkspace.git
cd LoopWorkspace
Scripts/update_feature_branch.sh
```

(Xcode is only needed for the optional tests. To build on the Mac in Xcode, also
put the team id in `Loop/Loop.xcconfig`. Never commit that file; the script
leaves it alone.)

## If the script stops

| Message | What to do |
|---|---|
| unsaved changes | Run `--undo`, then run the script again. |
| could not reach GitHub / authentication / push failed | The login token probably expired. Make a new one (below), then run the script again. |
| **merge conflict** | Loop changed the same lines the feature changed. This needs someone who reads Swift (see below). Run `--undo` to go back. |
| tests failed | Don't push. Same as a merge conflict. |

The GitHub build can also fail after a successful merge. That is the same case
as a merge conflict.

**Login token** (gh logs in with a token that only reaches the three Loop repos):
github.com → Settings → Developer settings → Fine-grained tokens → Generate.
Repository access: only `LoopWorkspace`, `Loop`, `LoopKit`. Permissions:
Contents *Read and write*, Workflows *Read and write*. Copy it, then in Terminal run
`pbpaste | gh auth login --with-token` and `gh auth setup-git`.
Never paste the token into a chat.

The `GH_PAT` secret that GitHub Actions uses is a different token. It is part of
regular Loop's setup and expires on its own schedule. LoopDocs ("Browser Build")
explains renewing it; renewing it fixes both builds.

**Merge conflict, without Claude:**
1. **Stay on the current build** for now. Rebuilding it still works; it just
   stays on the older Loop version. If the new Loop version fixes something
   important, use the safety net (regular Loop) until the feature is merged.
2. **Get help.** Give a Swift-literate friend or any AI coding tool this brief:
   *"Merging LoopKit's Loop release into my branch `feature/therapy-settings-history`
   gave a conflict in FILE (repo Loop or LoopKit). My side adds a therapy settings
   history; keep Loop's new code and re-add my lines. Commit the merge in that
   repo, then I'll run `Scripts/update_feature_branch.sh` again."* The script
   picks up from there.

## What happens to the history

- It is a file on the phone, inside Loop's own storage. Installing a newer feature
  build keeps it.
- On a regular Loop build, the file stays but nothing new is recorded. After going
  back to the feature build, recording resumes. Changes made in between show up as one
  change, dated when the feature build next saw them.
- Deleting the app deletes the history, and it may not move to a new phone.
  Screenshot it first.

## Rules

- `Loop/Loop.xcconfig` (personal team id) is never committed.
- TestFlight auto-update stays off.
- After installing a new build, watch it for a day. Previous Builds is the way back.
