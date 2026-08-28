# How CI works here

**Every workflow in this repository tests, builds or merges code that lives
somewhere else.** That is deliberate, and it is the first thing to understand
before changing any of them.

Nothing in this file goes beyond what the workflow YAML beside it already
states. Project history, planning material and machine configuration are kept in
the private repositories.

---

## Why the workflows are here

Private-repository Actions minutes bill against an account quota. That quota was
exhausted once, and when it was, **every workflow began failing before it
started** — zero steps, `log not found` — which blocked every merge and every
release at the same moment.

Public-repository runners are free. So the workflows moved here and are
**disabled, not deleted**, in the repositories they serve.

## They poll — they are not dispatched

The obvious design is for the private repository to send a
`repository_dispatch` when something needs building. That is circular: sending
one requires a workflow run *in the private repository*, which requires the
minutes that have run out.

So every workflow runs on a `schedule` and asks the private repository what needs
doing. A `repository_dispatch` and a `workflow_dispatch` path exist on each for
speed, but **the cron is never removed** — it is what survives the next
exhaustion.

> **Dispatch for speed, poll for survival.**

A pull request sitting at `BLOCKED` with no checks reported is usually waiting
for the next poll, not broken.

## The workflows

| File | Does |
|---|---|
| `private-pr-gate.yml` | The required check for the Android app: guards, static analysis, tests, coverage floor |
| `private-pr-gate-web.yml` | The required check for the web app: build, typecheck, tests, lint |
| `private-auto-merge.yml` | Squash-merges green pull requests; updates any that are behind |
| `private-auto-merge-web.yml` | The same, for the web app |
| `build_apk.yml` | Builds and publishes a release — **only on success**, so a broken build never ships and the last good artifact stays latest |
| `nightly-backup.yml` | Writes to the backups repository |
| `supabase-deploy.yml` | Deploys database migrations and functions |
| `cleanup-old-releases.yml` | Prunes superseded releases |
| `cleanup-old-runs.yml` | Prunes old workflow runs |

Each gate posts its verdict back as a **commit status** on the private
repository, matching the required check by exact context string. A typo in that
string produces a green status nobody is waiting for while the real one blocks
the pull request indefinitely.

## Running one by hand

Both gates accept a pull request number, which overrides the "already has a
verdict, skip it" rule:

```bash
gh workflow run private-pr-gate.yml     --repo Karthik77-kk/kfit -f pr=123
gh workflow run private-pr-gate-web.yml --repo Karthik77-kk/kfit -f pr=123
```

`build_apk.yml` accepts a manual dispatch too, and **a manual dispatch never
publishes a release.** That is intentional: dispatch is for reproducing a build,
not for shipping one.

## Rules that are easy to break by accident

1. **Never re-enable the disabled workflows in the private repositories.** A
   workflow's check-*run* outranks a commit *status* of the same name, so a dead
   `FAILURE` check-run keeps a pull request blocked while its statuses show
   green. That is what once made every pull request look mysteriously stuck.
2. **Never re-pin a required check to an app.** Deleting and re-adding a check in
   the settings UI silently re-pins it, after which externally posted statuses no
   longer satisfy it. Clear it with the per-check source dropdown → *Any source*.
3. **Every job sets `timeout-minutes`, least-privilege `permissions`, and a
   `concurrency` group.** The release build **queues, never cancels** — losing a
   release is worse than waiting.
4. **Keep the decision to build dynamic.** `build_apk.yml` computes the changed
   files at run time and skips when nothing app-relevant moved. A static path
   list goes stale silently; a rebuild of an unchanged app prompts every user to
   "update" for nothing.
5. **Validate the YAML before pushing** — `npx -y js-yaml <file>` — and confirm
   the gate's own guards still pass.

## Secrets

Referenced by name in the workflow files, and stored as Actions secrets on this
repository. They are **write-only once set**: a secret cannot be read back, so
rotating one means setting a new value, never recovering the old.

None of them is ever needed on a developer's machine. Local work authenticates
with `gh auth login`, which is per-machine and interactive.
