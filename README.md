# Upstream auto-sync for a private repo imported from a public repo

## Problem

A private GitHub repo was imported from a public repo. Keeping it current is a
manual loop:

1. Clone the private repo
2. `git remote add upstream <public repo>`
3. Pull from upstream and merge into the private branch
4. Push the private repo back to GitHub

Goal: automate as much of that as possible, and keep a human in the loop only
when a merge can't be done automatically.

## Design

Two pieces:

| File | Role |
|---|---|
| `templates/sync-upstream.yml` | **Primary.** A GitHub Actions workflow to install in the private repo as `.github/workflows/sync-upstream.yml`. It runs the sync on GitHub's runners, so no local clone is needed. It's kept under `templates/` so it doesn't run in this design repo. |
| `sync-upstream.sh` | **Fallback.** The same steps as a local script, for resolving conflicts by hand or running a sync on demand. |

### Workflow flow

```
schedule (daily) / manual "Run workflow"
        │
        ▼
checkout TARGET_BRANCH (full history)
        │
        ▼
add remote `upstream` → fetch UPSTREAM_BRANCH
        │
        ▼
upstream already contained in HEAD? ──yes──► exit (nothing to do)
        │ no
        ▼
git merge upstream/UPSTREAM_BRANCH
        │
   ┌────┴─────┐
 clean     conflicts
   │          │
   ▼          ▼
push to    abort merge; force-push upstream to CONFLICT_BRANCH;
TARGET     open a PR CONFLICT_BRANCH → TARGET (if not already open)
```

### Key decisions

- **Merge, not rebase or reset.** This matches the current manual process and
  keeps private commits safe. History is never rewritten on `TARGET_BRANCH`.
- **Never push a broken or partial merge.** On conflict, the target branch is
  left alone. The upstream code goes to a separate branch with a PR, so the
  conflict shows up in GitHub where you can resolve it (in the web editor or
  locally).
- **One PR for conflicts, reused.** `CONFLICT_BRANCH` has a fixed name and is
  force-pushed on each run, so later runs update the same open PR instead of
  opening new ones.
- **No-op when current.** The `merge-base --is-ancestor` check skips runs that
  have nothing to merge, so they don't create empty merge commits.
- **Upstream is read-only.** The upstream is public, so fetching it needs no
  credentials. The local script also sets the upstream push URL to `DISABLED`,
  so a slip of the fingers can't push private code to the public repo.
- **Concurrency guard.** Only one sync runs at a time.

### Configuration

Set these in the workflow's `env:` block:

| Variable | Meaning | Default |
|---|---|---|
| `UPSTREAM_REPO` | `owner/name` of the public repo | *(must set)* |
| `UPSTREAM_BRANCH` | Branch to pull from upstream | `main` |
| `TARGET_BRANCH` | Branch in the private repo to update | `main` |
| `CONFLICT_BRANCH` | Side branch used for conflict PRs | `upstream-sync` |

The schedule is the `cron:` line (default: daily at 06:00 UTC).

### Authentication and known limits

- **The default `GITHUB_TOKEN` is enough for most cases**, with one important
  exception: GitHub refuses pushes that change files under
  `.github/workflows/` unless the token has the `workflow` scope, which
  `GITHUB_TOKEN` can't get. If upstream ever changes its own workflows, the
  push will fail. Fix: create a fine-grained PAT (Contents: read/write,
  Pull requests: read/write, Workflows: read/write on the private repo) and
  store it as the repo secret `SYNC_TOKEN`. The workflow uses it automatically
  when it is present.
- **Pushes made with `GITHUB_TOKEN` don't trigger other workflows** (for
  example, CI on push). Using `SYNC_TOKEN` avoids this as well.
- **PR creation with `GITHUB_TOKEN`** requires the repo setting *Settings →
  Actions → General → "Allow GitHub Actions to create and approve pull
  requests"*. This isn't needed with `SYNC_TOKEN`.
- **Branch protection** on `TARGET_BRANCH` that blocks direct pushes will stop
  the clean-merge path. Either allow the token's identity to bypass it, or
  change the workflow so it always opens a PR.
- **Workflow file name collision.** If upstream ever adds its own
  `.github/workflows/sync-upstream.yml`, the merge will conflict. Rename the
  file if that happens.

## Using the local script

```sh
cd /path/to/private-repo-clone
/path/to/sync-upstream.sh owner/public-repo [upstream-branch] [target-branch]
```

Keep the script **outside** the private repo and call it by path. A copy
inside the repo is an untracked file, which trips the clean-tree check.

Requirements: `origin` points to the private repo and you can push to it
(the SSH key or HTTPS credentials you cloned with). The upstream is public,
so it needs no credentials. The target branch must exist on `origin` and
must not have unpushed local commits.

The script:

1. Refuses to run with a dirty working tree.
2. Adds or updates the `upstream` remote and disables pushing to it.
3. Fast-forwards the target branch from `origin`.
4. Fetches and merges upstream.
5. Pushes on a clean merge. On conflict, it stops and tells you how to finish.

To resolve a conflict PR the workflow opened, check out `TARGET_BRANCH`, run
the script, fix the conflicts, then commit and push. The PR closes
automatically once its commits are in `TARGET_BRANCH`.

## Moving this into the real repo

1. Copy `templates/sync-upstream.yml` to `.github/workflows/sync-upstream.yml`
   in the private repo and set
   `UPSTREAM_REPO` (and the branches if they aren't `main`). A file that
   exists only in the private repo never conflicts during syncs, unless
   upstream adds a file at the same path.
2. Recommended: add the `SYNC_TOKEN` secret.
   - Create a fine-grained PAT scoped to the private repo with Contents,
     Pull requests and Workflows set to read/write.
   - From the private clone, run `gh secret set SYNC_TOKEN` and paste the token.
   - Note the expiry date. When the token expires, syncs fail at checkout or
     push. Regenerate the token and run `gh secret set SYNC_TOKEN` again.
3. Commit to the default branch. Scheduled workflows only run from there.
4. Trigger it once by hand and watch it:
   ```sh
   gh workflow run sync-upstream.yml
   gh run watch
   ```
   Right after a manual sync, the expected result is "Already up to date".

## Resolving merge conflicts

When a merge stops on conflicts (in the script, or locally for a conflict PR),
nothing has been pushed yet. Run `git merge --abort` at any point to back out.

List the conflicted files:

```sh
git diff --name-only --diff-filter=U
git status            # shows the kind of each conflict
```

Resolve each file according to the kind of conflict `git status` reports:

| `git status` says | Porcelain code | Typical fix |
|---|---|---|
| both modified | `UU` | Edit the file, remove the `<<<<<<<` / `=======` / `>>>>>>>` markers, then `git add`. To keep one side of the whole file, run `git checkout --ours <file>` (private) or `git checkout --theirs <file>` (upstream), then `git add`. |
| both deleted | `DD` | `git rm <file>`. This usually means each side renamed the file differently. Look for matching "added by" entries. |
| added by them | `UA` | `git rm <file>` drops upstream's copy. `git add <file>` keeps it. |
| added by us | `AU` | `git add <file>` keeps your copy. `git rm <file>` drops it. |

Bulk versions (substitute the code and the command):

```sh
git status --porcelain | awk '/^DD /{print substr($0,4)}' | xargs -I{} git rm --quiet -- "{}"
git status --porcelain | awk '/^UA /{print substr($0,4)}' | xargs -I{} git rm --quiet -- "{}"
git status --porcelain | awk '/^AU /{print substr($0,4)}' | xargs -I{} git add -- "{}"
```

Review what will be committed before finishing:

```sh
git diff --cached --stat                          # files and size of changes
git diff --cached -- <file>                       # change vs. your branch
git diff --cached upstream/main -- <file>         # difference from upstream
```

Finish the merge:

```sh
git commit --no-edit
git push origin main
```

Recurring conflicts are likely, because upstream keeps touching the same
files. Run this once in the private clone so Git reuses your earlier
resolutions:

```sh
git config rerere.enabled true
```

## Troubleshooting

**"Working tree is not clean" / uncommitted changes.** There are usually two causes:
- A copy of `sync-upstream.sh` is inside the repo. Move it out.
- A previous merge was left unfinished. Run `git status`. If it shows
  "unmerged paths", finish the merge or run `git merge --abort`.

**`gh`: "No default remote repository has been set".** The clone has two
GitHub remotes (`origin` and `upstream`). Point `gh` at the **private** repo
once:

```sh
gh repo set-default <owner>/<private-repo>
```

Alternatively, pass `-R <owner>/<private-repo>` on each `gh` command.

**`remote: warning: ... larger than GitHub's recommended maximum file size of 50.00 MB`.**
This is a warning only, and the push succeeds. The large files come from
upstream. Don't convert them to Git LFS in the private repo: that rewrites
the private history away from upstream's and causes conflicts on every
sync. Act only if upstream adds a file over GitHub's **100 MB** hard limit,
which GitHub will reject.

**VS Code flags `secrets.SYNC_TOKEN` ("Context access might be invalid").**
The secret doesn't exist in the repo yet. The workflow still runs because
it falls back to `github.token`. Add the secret and reload VS Code to clear
the warning.

**"Node.js 20 is deprecated ... actions/checkout@v4".** Use
`actions/checkout@v5` or later. The workflow here already does.

**Upstream's own workflows run in the private repo.** Workflows that upstream
keeps in `.github/workflows/` are merged in and run in the private repo,
where they may fail for lack of upstream's secrets. To turn one off, open
**Actions → (workflow) → ⋯ → Disable workflow**.

**Ignoring local editor files (e.g. `.vscode/`).** Use
`.git/info/exclude`, not `.gitignore`. Editing `.gitignore` (which upstream
also tracks) risks merge conflicts on every sync:

```sh
echo ".vscode/" >> .git/info/exclude
```

To ignore it in every repo on this machine, add it to a global ignore file
(`git config --global core.excludesFile ~/.gitignore_global`).
