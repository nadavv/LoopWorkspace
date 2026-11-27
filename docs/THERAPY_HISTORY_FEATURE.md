# Therapy settings history build: quick guide

**Every ~2 months** (TestFlight builds expire after 90 days):

1. GitHub → nadavv/LoopWorkspace → Actions → **4. Build Loop** → Run workflow →
   branch **feature/therapy-settings-history** → Run.
2. When it finishes (~1 hour), TestFlight → Loop → install that build.

**When a new Loop version comes out:**

3. On the Mac, in Terminal: `cd ~/xcode/Loop/LoopWorkspace`
4. Run `Scripts/update_feature_branch.sh` and answer `y` to each question.
5. Do steps 1–2.
6. Watch Loop for a day. If something's wrong: TestFlight → Previous Builds.

**If something goes wrong:**

7. Script says "authentication": run `gh auth login`, then step 4 again.
8. Script says "merge conflict": run `Scripts/update_feature_branch.sh --undo`
   and ask someone who knows Swift (or an AI coding tool) for help.
9. Stuck? Install the newest regular Loop build from TestFlight; it builds itself
   monthly. Settings carry over.

**Always:** keep TestFlight auto-update off, and screenshot the History before
deleting the app or switching phones.
