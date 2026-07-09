# Karthik Fitness — Claude Code Guide

## Project Overview
Personal Flutter fitness tracker for Karthik (Bangalore, India) focused on fat loss and muscle retention.
- **Platform**: Android (primary), Flutter 3.44.0, Dart SDK ≥3.2
- **Architecture**: Provider + ChangeNotifier, SharedPreferences persistence
- **State**: Single `FitnessProvider` — all app state lives here

## Key Files

| Path | Purpose |
|------|---------|
| `lib/main.dart` | App entry, theme, bottom nav |
| `lib/providers/fitness_provider.dart` | All state, persistence, computed properties |
| `lib/models/models.dart` | Data models + food database (Indian foods) |
| `lib/screens/home_screen.dart` | Dashboard — rings, charts, smart tip |
| `lib/screens/nutrition_screen.dart` | Tabbed container: Food \| Water \| Supplements |
| `lib/screens/food_screen.dart` | Food logging by meal type (embeddable) |
| `lib/screens/water_screen.dart` | Water intake tracking |
| `lib/screens/workout_screen.dart` | Workout logging, per-exercise MET calories |
| `lib/screens/stats_screen.dart` | Body data entry, 1RM calculator, weight chart |
| `lib/screens/smart_scale_screen.dart` | Smart scale body composition logging |
| `lib/screens/supplements_screen.dart` | Whey/creatine/multivitamin toggle |
| `lib/screens/history_screen.dart` | 60-day history view |
| `lib/screens/settings_screen.dart` | Goals, export/import, notifications |
| `lib/services/notification_service.dart` | flutter_local_notifications, exact alarms |

## Daily Targets (user-configurable, defaults)
- Calories: 1700 kcal · Protein: 100g · Water: 2500 mL · Steps: 8000

## User Profile Defaults
- Height: 160 cm, Age: 24, Goal weight: 70 kg, Name: Karthik

---

## ⚡ Development Workflow (MANDATORY)

### Rule 0 — 🚫🚫🚫 UNBREAKABLE: NEVER DISABLE BRANCH PROTECTION 🚫🚫🚫
**Branch protection MUST STAY ENABLED AT ALL TIMES. THIS IS ABSOLUTE. NO EXCEPTIONS.**

- ❌ NEVER disable without explicit user permission
- ❌ NEVER bypass it
- ❌ NEVER work around it
- ❌ NEVER use admin privileges to force merge

**IF PROTECTION BLOCKS A PUSH:**
1. Create feature branch: `feature/build-X-*` or `fix/build-X-*`
2. Push to feature branch
3. Let dual-agent system approve and auto-merge
4. NEVER disable protection as a workaround

**TO DISABLE PROTECTION (REQUIRES EXPLICIT USER PERMISSION):**

Claude may ONLY disable protection if user explicitly requests it. Process:
1. User types: "disable branch protection" (explicit request)
2. Claude responds: "⚠️ Are you sure? Disabling protection breaks the entire automation system. Type 'yes, disable it' to confirm."
3. User confirms: "yes, disable it"
4. ONLY THEN: Claude disables protection
5. Claude immediately re-enables after task completes
6. Claude logs the disable/enable in commit message

**Why:** Branch protection IS the system. Disabling it breaks automation, enforcement, and trust. All changes go through feature branches and dual-approval. No shortcuts. Ever.

**See:** [rule_never_disable_branch_protection.md](../memory/rule_never_disable_branch_protection.md)

---

### Rule 1 — Never commit directly to `main`
All changes go in a feature branch. `main` is protected — only merged via PR or fast-forward after full review.

### Rule 2 — Branch naming
```
feature/build-N-short-description    # new features
fix/build-N-short-description        # bug fixes
refactor/short-description           # refactors (no build bump)
```
Example: `feature/build-43-step-goal-settings`

### Rule 3 — One feature per branch
Keep branches focused. If adding 3 features, use 3 branches.

### Rule 4 — Bump build number before merging
Every merge to `main` that ships a new APK must bump `pubspec.yaml` version:
- `versionName` (e.g. `1.0.0`) — bump for significant releases
- `versionCode` (`+N`) — bump on EVERY merge — **MUST be a whole integer** (Android requires it)
- **New features** → next integer: `76` → `77`
- **Patches/fixes** → also next integer: `77` → `78` (do NOT use `77.1` — decimals break Android versionCode)
- The branch name and commit message can say "Build 77.1" for human readability, but pubspec must have `+78`
Current build: **95**. Next build: **96**.

### Rule 4a — CRITICAL: Keep pubspec.yaml version code in sync with commit messages
**This rule prevents release automation failures, download 404 errors, and website deployment confusion.**

- **EVERY commit with "Build N" in the message MUST have pubspec.yaml with `+N`**
- Before merging to main, verify: `git diff` shows `pubspec.yaml version: 2.3.0+N` where N matches commit message "Build N"
- If commit says "Build 85", pubspec MUST say `+85` (not `+83` or `+84`)
- If pubspec and commit mismatch: GitHub Actions will create the wrong release tag, website won't find the APK, Cloudflare deployment will fail
- **Pre-merge check**: `grep "version:" pubspec.yaml` and `git log -1 --oneline` — they must align

Example of CORRECT state:
```
Commit:    "Build 86: Add feature X"
pubspec:   version: 2.3.0+86  ✅
Result:    GitHub creates release v2.3.0+86 with APK asset
```

Example of BROKEN state (happened June 6, 2026):
```
Commit:    "Build 85: Fix duplicate dlBtn..."
pubspec:   version: 2.3.0+83  ❌
Result:    GitHub creates release v2.3.0+83 (wrong!), website can't find v2.3.0+85 release
```

### Rule 5 — Commit message format
```
Build N: short imperative summary of what changed
```
Examples:
- `Build 46: add weekly progress chart`  ← new feature
- `Build 45.1: fix CI settings.gradle.kts path`  ← patch/fix to build 45

### Rule 6 — Pre-merge checklist (Claude must do ALL before merging)
1. `flutter analyze` — zero errors, zero warnings
2. `flutter test` — all tests pass
3. **`flutter build apk --release` — MANDATORY for ANY change touching Gradle/Android files.**
   - Required when changed: `build.gradle.kts`, `settings.gradle.kts`, `pubspec.yaml` deps, `AndroidManifest.xml`, any `android/` file
   - Not required for pure Dart-only changes (provider, screens, models, tests)
   - Build must complete with `✓ Built build/app/outputs/flutter-apk/app-release.apk`
   - If it fails locally it WILL fail in CI — fix it before pushing
4. Code review — correctness, no regressions, follows conventions
5. Diff review — confirm only intended files changed
6. Bump `pubspec.yaml` version code
7. **`git push origin <branch-name>` — MANDATORY. Branch MUST exist on remote before merging.**
8. Merge to `main` → CI auto-triggers → APK built

### Rule 8 — MANDATORY: Push branch to remote before merging
**This rule cannot be skipped under any circumstances.**
- The branch MUST be pushed to GitHub (`git push origin <branch-name>`) before `git merge` is run.
- A branch that only exists locally provides no audit trail and cannot be reviewed.
- Even for a one-line hotfix, the remote push is non-negotiable.
- Correct sequence — no exceptions:
```
git push origin fix/build-N-description    # ← CANNOT SKIP THIS
git checkout master
git merge --no-ff fix/build-N-description
git push origin master
git branch -d fix/build-N-description
git push origin --delete fix/build-N-description
```

### Rule 7 — After merge
- Delete the local AND remote feature branch
- Verify GitHub Actions run succeeds
- APK artifact appears under Actions → latest run

### Rule 9 — 🚫 MANDATORY FULLY-AUTOMATIC QUALITY GATE (UNBREAKABLE)
**This rule cannot be broken. No exceptions. Ever. NO USER PERMISSION NEEDED.**

> ⚠️ **MECHANISM UPDATED (Build 95).** The old "post `✅ Code Review Agent: APPROVED`
> / `✅ Testing Agent: VERIFIED` comment strings and let a workflow grep for them"
> approval is **GONE** (it was fakeable — any comment containing the string merged
> the PR). Replaced by a **real** CI gate. There is no Haiku/Claude CI job — review is
> done by **GitHub Copilot** (advisory) per `.github/copilot-instructions.md`.
>
> - **`pr-quality-gate.yml` → `verify` job** (the hard, un-fakeable, REQUIRED gate):
>   `flutter analyze --no-fatal-infos` + `flutter test` on the real head commit, plus
>   a **version-integrity check** (versionCode must be a whole integer; the implied
>   release tag must not already exist). Branch protection requires this; it resets
>   on every push.
> - **`auto-merge.yml`**: enables GitHub native squash auto-merge; the PR merges
>   itself once the required gate passes (needs repo setting "Allow auto-merge" ON).
> - **`build_apk.yml`** (unchanged): on push to main, builds + creates the release
>   ONLY on success — so a broken build never ships; the last good APK stays "latest".
>
> **Nobody posts approval strings anymore; there is nothing to "fake."** To merge a PR:
> push the branch → the gate runs → Copilot comments → fix what matters → it auto-merges
> when green. The STEP 1–5 comment-string flow below is HISTORICAL — ignore it.

### ⚡⚡⚡ CRITICAL: ZERO USER INPUT — EVERYTHING AUTOMATIC ⚡⚡⚡

**Claude Code MUST NEVER ask user for permission. FULL AUTONOMY REQUIRED.**

Forbidden phrases:
- ❌ "Should I run /code-review?"
- ❌ "Do you want me to fix this?"
- ❌ "Should I re-run the agents?"
- ❌ "Should I merge to main?"
- ❌ "Do you want me to..."

**Required behavior:**
- ✅ Create branches WITHOUT asking
- ✅ Invoke agents IMMEDIATELY (no prompts)
- ✅ Fix issues IMMEDIATELY when found
- ✅ Re-run agents AUTOMATICALLY
- ✅ Keep fixing until BOTH agents approve
- ✅ Let GitHub auto-merge automatically
- ✅ Post status updates (no permission needed)

---

1. **No direct commits to main (ENFORCED BY GIT BRANCH PROTECTION)**
   - Branch protection blocks ALL direct pushes to main
   - Cannot be bypassed (even with admin privileges)
   - All changes MUST go through feature branches + PR workflow

2. **Code Review Agent (Haiku model ONLY) - INVOKED AUTOMATICALLY**
   - Model: `claude-haiku-4-5` (mandatory, fastest, sufficient)
   - Effort: `medium` (3+4 angles, 6 candidates each)
   - **7-angle comprehensive analysis**:
     1. **Correctness (3 angles)**: Line-by-line scan, removed-behavior audit, cross-file tracer
     2. **Cleanup (3 angles)**: Reuse check, simplification, efficiency
     3. **Altitude (1 angle)**: Is this a proper fix or bandaid?
   - **Must verify ALL**:
     - No syntax errors, type violations, compile breaks
     - No logic bugs, off-by-one errors, null dereferences, missing awaits
     - No removed safety guards or dropped error paths
     - No breaking changes to call sites
     - No code duplication (reuse existing helpers)
     - No unnecessary complexity
     - Fix is correct, complete, no hidden bugs
     - No unintended changes to other files
     - No regressions in adjacent code
     - No edge case failures
   - **Verdict**: `✅ Code Review Agent: APPROVED — [findings or "clean"]`
   - **Posts automatically** to PR comments (no manual action)
   - **Cannot merge without this** (blocked by branch protection)

3. **Testing Agent (Haiku model ONLY) - INVOKED AUTOMATICALLY**
   - Model: `claude-haiku-4-5` (mandatory, sufficient for testing)
   - **8-point comprehensive verification**:
     1. Build verification: `flutter build apk --release` succeeds
     2. Static analysis: `flutter analyze` → zero errors, zero warnings
     3. Unit tests: `flutter test` → 100% pass rate
     4. Test coverage: all code paths tested (boundaries, zero values, all branches)
     5. Edge cases: null inputs, empty lists, concurrent access
     6. Regression checks: existing tests still pass
     7. Integration checks: all dependencies correct, no breaking changes
     8. Performance: no new slow operations (network, I/O in hot paths)
   - **Must verify ALL**:
     - All tests pass (0 failures)
     - Zero build errors
     - Zero warnings (info-level lints OK)
     - Code coverage acceptable for changed code
     - No regressions in other tests
     - No new performance bottlenecks
     - APK builds for release (if Android files changed)
   - **Verdict**: `✅ Testing Agent: VERIFIED — [results/findings]`
   - **Posts automatically** to PR comments (no manual action)
   - **Cannot merge without this** (blocked by branch protection)

4. **Fully Automatic Workflow (ZERO USER PERMISSION REQUIRED)**
   ```
   STEP 1: Create & Push Branch (automatic)
     git checkout -b feature/build-X-description
     [make changes]
     pubspec.yaml: bump version to +X
     git commit -m "Build X: description"
     git push origin feature/build-X-description
   
   STEP 2: Invoke Code Review (AUTOMATIC - NO ASKING)
     /code-review runs immediately
     ↓
     If REJECTED:
       → Claude reads issues
       → Claude fixes code immediately
       → Claude amends commit
       → Claude force-pushes to remote
       → Re-run /code-review AUTOMATICALLY
       → Repeat until APPROVED
     ↓
     If APPROVED:
       → Agent posts: ✅ Code Review Agent: APPROVED — [findings]
       → Continue automatically
   
   STEP 3: Invoke Testing (AUTOMATIC - NO ASKING)
     /verify runs immediately
     ↓
     If REJECTED:
       → Claude reads failures
       → Claude fixes code immediately
       → Claude amends commit
       → Claude force-pushes to remote
       → Re-run /verify AUTOMATICALLY
       → Repeat until VERIFIED
     ↓
     If VERIFIED:
       → Agent posts: ✅ Testing Agent: VERIFIED — [results]
       → Continue automatically
   
   STEP 4: GitHub Workflows Auto-Detect & Merge (AUTOMATIC)
     check-agent-approvals.yml monitors PR comments
     ↓
     Detects both ✅ approvals
     ↓
     Updates status check: dual-agent-approval → SUCCESS
     ↓
     auto-merge-on-approval.yml triggers
     ↓
     GitHub enables auto-merge (squash strategy)
     ↓
     PR merges automatically to main
     ↓
     Feature branch deleted automatically
   
   STEP 5: Build & Deploy (AUTOMATIC)
     build_apk.yml triggers on main push
     ↓
     Builds APK with gh CLI
     ↓
     Verifies APK exists
     ↓
     Creates release v2.3.0-build-X
     ↓
     Uploads to GitHub CDN
     ↓
     Cloudflare auto-deploys website
     ↓
     Website fetches /releases/latest
     ↓
     Download button works ✅
   ```

5. **Automatic Issue Resolution (MANDATORY - NO ASKING)**
   - Agent finds issues? FIX IMMEDIATELY
   - Version mismatch? FIX IMMEDIATELY
   - Tests fail? FIX IMMEDIATELY, RE-RUN TESTS
   - Build fails? FIX IMMEDIATELY, REBUILD
   - Type errors? FIX IMMEDIATELY
   - **NEVER ASK PERMISSION**

6. **Violations = Immediate Rollback & Correction**
   - Direct commit to main detected → REVERT IMMEDIATELY
   - Skipped code review → REVERT IMMEDIATELY
   - Skipped testing → REVERT IMMEDIATELY
   - Merged with failing tests → REVERT IMMEDIATELY
   - Asked user for permission → FIX AUTONOMY IMMEDIATELY

**See:** [Automated Dual-Approval Workflow](../memory/rule_automated_dual_approval_workflow.md) for full details.

### Rule 10 — NEVER change applicationId
The `applicationId` in the CI workflow (`build_apk.yml` line ~114) is **permanently fixed** at `com.example.karthik_fitness`.
- **Changing applicationId = different app on the device.** Android treats it as a brand-new app, not an update. Every user must uninstall and lose their data.
- The original "can't install" error (Builds 74–75) was caused by **decimal versionCodes**, NOT by applicationId. Changing applicationId was the wrong fix.
- Current value: `applicationId "com.example.karthik_fitness"` — do not touch, ever.
- If this rule is ever broken in error: **immediately revert** before any user installs the bad APK.

### Rule 11 — namespace ≠ applicationId (they are different)
In Android, these two fields serve completely different purposes:
- `namespace` = Java/Kotlin source package for R class generation. **Must match the package declarations in committed .kt files** (`com.example.karthik_fitness`). Changing this breaks compilation.
- `applicationId` = The app's identity on the device and Play Store. Changing this breaks updates for existing users.
- They are set separately in the CI-generated `build.gradle`. Current correct values:
  ```
  namespace  "com.example.karthik_fitness"   ← matches .kt source files
  applicationId "com.example.karthik_fitness" ← matches what's installed on device
  ```
- Never conflate the two. Never change either without understanding the consequences.

### Rule 12 — versionCode must be a whole integer, always
- `pubspec.yaml` version format: `versionName+versionCode` (e.g. `2.3.0+82`)
- **versionCode MUST be a plain integer** — Flutter/Android truncates decimals silently.
  - ✅ `2.3.0+82` → versionCode 82
  - ❌ `2.3.0+81.1` → versionCode 81 (same as previous, Android rejects the update)
- Every merge to master — feature OR fix — increments the integer by 1.
- Branch names and commit messages may use "Build 81.1" notation for human readability, but `pubspec.yaml` must always have `+82` (the next integer).
- Lesson: Builds 72.1, 74.1, 74.4, 75.1 all shipped with duplicate versionCodes, causing "can't install" errors for users. Never again.

### Rule 13 — Mandatory agent approval before merge to main
**NO feature branch merges to main WITHOUT explicit approval from both Review Agent and Testing Agent.**

This is a quality gate requirement:
- **Review Agent**: Comprehensive code review (syntax, conventions, no breaks, security, design)
- **Testing Agent**: Full test execution (unit tests, integration tests, edge cases, regressions)

Both agents must explicitly approve (PASS verdict) before merge is allowed. This prevents bugs, regressions, and breaks from reaching production.

**Merge workflow (MANDATORY):**
1. Push feature branch to remote (Rule 8)
2. Deploy Review Agent → comprehensive code audit → await PASS verdict
3. Deploy Testing Agent → run full test suite → await PASS verdict
4. **ONLY if both approve:** Merge to main via `git merge --no-ff`
5. If either rejects: Fix issues, recommit, re-review, re-test until both PASS

### Rule 14 — Agent approval signatures in commit messages (no AI co-author trailer)
When merging after agent approval, the merge commit message MUST include approval signatures, but must NOT include a `Co-Authored-By: Claude ...` (or any AI-assistant) trailer — see Rule 18:

```
Build N: description

✅ Review Agent: PASS — [summary of code review findings]
✅ Testing Agent: PASS — [summary of test results: X/X passing, 0 failures]
```

This creates an audit trail showing quality gate approval history.

### Rule 15 — Agent model specification for code review and testing
**All Review and Testing agents MUST use Haiku model ONLY.**

- **Review Agent**: `model: "haiku"` — Fast code audits, syntax checking, rule compliance
- **Testing Agent**: `model: "haiku"` — Fast test execution, result analysis, validation

Why Haiku:
- ✅ Sufficient capability for structured review/testing tasks (not creative work)
- ✅ 2-3x faster than Sonnet/Opus
- ✅ Lower cost (important for frequent merge-to-main operations)
- ✅ Deterministic output (suitable for pass/fail verdicts)
- ❌ NOT suitable for: architecture design, creative problem-solving, complex multi-step planning

**Implementation:**
```yaml
# Review Agent
subagent_type: code-review
model: "haiku"  # MANDATORY

# Testing Agent  
subagent_type: testing
model: "haiku"  # MANDATORY
```

This rule ensures efficient quality gates without sacrificing review quality.

### Rule 16 — Branch from the LATEST `main`; do NOT stack branches or hand-bump the version
**This rule exists because violating it silently breaks CI.** PRs merge with **squash**,
and `build_apk.yml` **auto-derives `versionCode` from the commit count** — so manual
`pubspec.yaml` / `lib/app_info.dart` version bumps are unnecessary AND dangerous.

- ✅ Always branch each feature/fix from up-to-date main:
  `git fetch origin && git checkout -b <name> origin/main`
- ❌ Never base a new branch on another in-flight feature branch (no stacking).
- ❌ Do not manually bump the version. (If `app_info.dart` must change for the
  About screen, keep `pubspec` and `app_info` in sync so `app_version_test` passes,
  and rebase onto latest `main` before requesting merge.)

**Why:** when you stack branches and hand-bump the version line, then an earlier PR
squash-merges, the later branches diverge from `main` on that line → **merge
CONFLICT**. GitHub does **not** run `pull_request` workflows on a conflicting PR, so
the **PR Quality Gate never dispatches** and the PR can't auto-merge. It looks exactly
like "Actions isn't running" or "we hit a quota cap" — but it's a silent conflict block.
(This is what stranded Builds 110/111 in PRs #36/#37.)

**Diagnose before assuming an outage:** `gh pr view <n> --json mergeable,mergeStateStatus`.
`CONFLICTING` / `DIRTY` is the real cause — fix with `git merge origin/main`, resolve the
version line, push (that re-triggers the gate). A fresh non-conflicting PR running fine
proves Actions is up.

> ⚠️ This **supersedes the manual-bump guidance** in Rules 4 / 4a / 12 above: those
> predate the commit-count `versionCode` automation. Do not hand-bump `+N` anymore.

### Rule 17 — arm64-only APK needs `--target-platform` AND a jniLibs filter (not `abiFilters`)
The APK weight is `flutter_gemma`'s MediaPipe/LiteRT **native inference runtime**, NOT the model — the ~600 MB Gemma 3 is **downloaded at runtime**, never bundled (`assets/` is ~0.4 MB). A true single-ABI APK needs BOTH, each targeting a different lib source:
- `flutter build apk --target-platform android-arm64` → strips the **Flutter**-built libs (libflutter/libapp/libdartjni) for other ABIs.
- `packagingOptions { jniLibs { excludes += ['**/x86_64/**','**/armeabi-v7a/**'] } }` in the **CI-generated** `build.gradle` (inside `build_apk.yml`) → strips the **AAR-shipped MediaPipe `.so`** for other ABIs.

`ndk { abiFilters "arm64-v8a" }` alone does **not** filter prebuilt `.so` from dependency AARs — that's why #72's filter never shrank the APK. Size path: 297 → (#78 image-gen excl.) 260 → (#81 `--target-platform`) 220 → (packaging filter) ~170 MB. **Always edit the gradle in `build_apk.yml`**, never the committed `android/app/build.gradle` (CI regenerates it).

### Rule 18 — Never attribute commits to AI assistants (no `Co-Authored-By: Claude`/AI trailers)
No commit in this project — feature branches, merges, hotfixes, docs, anywhere — should include a `Co-Authored-By: Claude ...`, `Co-Authored-By: <any AI assistant> ...`, or similar AI-attribution trailer. This overrides Claude Code's own default commit-message behavior specifically for this project.

**Why:** GitHub recognizes these trailers and lists the AI as a repo contributor in the Contributors graph/sidebar — confirmed 2026-07-09 on the public `kfit` distribution repo, which was showing a "claude" bot entry alongside the real owner. That's public-facing and was fixed by squashing `kfit`'s history to a single fresh commit (contributors: Karthik77-kk only).

**How to apply:** When creating any commit, never add a co-author line naming an AI/model. Rule 14's approval signatures (✅ Review Agent: PASS / ✅ Testing Agent: PASS) stay — only the AI co-author trailer is dropped.

### Rule 19 — PR titles become user-facing changelog text: keep them short, generic, and detail-free
Every PR is squash-merged, so the squash commit's subject line **is** the PR title. `build_apk.yml`'s "Compose dynamic release notes" step extracts commit **subjects only** (`git log --pretty=format:'%s'`) straight into the GitHub release body — which the in-app updater then shows to the end user as "What's new." **The PR title is a changelog bullet, not an internal label.**

**Why:** 2026-07-09 — two internal/CI-focused PR titles ("Docs: drop AI co-author trailer requirement", "CI: weekly release cleanup on kfit") were about to ship verbatim as update-dialog text. For security-hardening work specifically, this is worse than unpolished — describing the exact mechanism being added (signing checks, tamper detection, etc.) in text a modified/redistributed copy's user could also read is counterproductive.

**How to apply:**
- Write PR titles like a real app changelog entry: short, plain-language, generic — e.g. "Reliability and stability improvements," "Bug fixes," "Under-the-hood improvements."
- Never put internal jargon in the title: no CI/workflow/keystore/tamper/signing/secrets/agent/gate/PR/repo terminology, no security-mechanism specifics, no build/rule numbers.
- All real technical detail — the actual why/what/how — goes in the **PR description and commit body** instead. Only the subject line (`%s`) is ever extracted into release notes; the body never is.

---

## Build & Run Commands
```powershell
# Feature branch workflow
git checkout master && git pull origin master
git checkout -b feature/build-N-description

# Dev cycle
flutter pub get
flutter run                          # on connected Android device
flutter analyze                      # must be clean before merge
flutter test                         # must pass before merge

# Release
flutter build apk --release

# Merge workflow (ALL steps mandatory — Rule 8)
git add -p                                      # stage only intended changes
git commit -m "Build N: description"
git push origin feature/build-N-description     # MANDATORY — remote push before merge
git checkout master
git merge --no-ff feature/build-N-description
git push origin master                           # triggers CI
git branch -d feature/build-N-description
git push origin --delete feature/build-N-description  # delete remote branch too

# Device
adb devices
adb install build\app\outputs\flutter-apk\app-release.apk
adb logcat -s flutter
```

## Dependencies (Build 42)
- `provider` — state management
- `shared_preferences` — local persistence
- `fl_chart` — charts
- `intl` — date formatting
- `uuid` — unique IDs
- `flutter_local_notifications` — exact alarm notifications
- `pedometer` — live step counting
- `path_provider` — file export path
- `share_plus` — share export file
- `file_picker` — import JSON backup
- `cupertino_icons` — iOS-style icons

## Architecture Notes
- **No backend** — SharedPreferences only, no database, no auth
- **Data retention**: workouts 90d · body 180d · scale 365d · food/water/supps 60d
- **Food DB**: static `const List<FoodItem>` in models.dart — no network lookup
- **Goals**: user-configurable (calorie, protein, water, steps) — NOT hardcoded anymore
- **Calories**: food + supplement calories (whey=120kcal) + carb/fat estimates
- **Burn**: resting (BMR prorated) + walking (steps × MET) + workout (per-exercise MET)
- **BMR**: scale BMR takes priority over Mifflin-St Jeor if SmartScale logged
- **Pedometer**: live stream with day-baseline, midnight reset detection

## Color Palette (dark theme)
- Background: `#000000` · Card: `#1C1C1E` · Primary: `#30D158` (green)
- Secondary: `#40C8E0` (cyan) · Error: `#FF453A` · Warning: `#FF9F0A` · Muted: `#8E8E93`

## Common Patterns
```dart
// Provider in build (rebuilds on change)
final p = context.watch<FitnessProvider>();

// Provider in callbacks (no subscription)
context.read<FitnessProvider>().addFoodEntry(entry);

// SharedPreferences key format
'food_YYYY-MM-DD'   'water_YYYY-MM-DD'   'supp_YYYY-MM-DD'
'workouts'          'body_history'        'scale_history'

// Goals — use p.calorieGoal not FitnessProvider.kCalorieGoal
// kCalorieGoal is an alias kept for backward compat, prefer instance getter
```

## GitHub Actions
`.github/workflows/build_apk.yml` — triggers on push to `master` or `main`.
Builds Flutter 3.44.0 release APK, uploads as artifact (30-day retention).
