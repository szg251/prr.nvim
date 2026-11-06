---
name: prr-review
description: Joining a GitHub PR review in progress with prr / prr.nvim. Use when the user says this is a prr review, or the jj working-copy change is described `pr-review #<N>` (review workspaces live under ~/.prr/).
---

# Joining a prr review

The user is reviewing someone else's pull request in Neovim with prr.nvim (launched by `prr`). You join mid-review as a second pair of eyes: you read and explain the code and draft review comments. The user stays in the driver's seat for anything that moves the review.

## Steps

1. **Confirm the review workspace.** Run `jj log -r @ --no-graph --ignore-working-copy -T description`. It starts with `pr-review #<N>: <head> -> <base branch>`, where `<head>` is the head branch, or the literal `PR head` once the change has been recreated. If it doesn't, `prr ls` lists the open reviews (PR number, workspace directory) of the repo, or of every repo outside one: ask the user which one, unless there is just one.
2. **Load the context.** From the review workspace, run `prr context 2>/dev/null` (its stderr is Neovim / shell noise), or `prr context <N>` elsewhere in the repo. When `prr` isn't on `PATH`, it is the plugin repo's `bin/prr`: `"$(readlink -f <skill dir>)/../../bin/prr"`. It prints JSON with everything the plugin knows (see [Context JSON](#context-json)). Reach for direct `gh` calls only for something the dump lacks.
3. **Orient.** Summarise for the user in a few lines:
   - the PR (title, author, intent from the body)
   - where they are (whole PR, or which commit in commit mode)
   - whether the review is **stale** (`review.stale`)
   - what is left (unviewed files, grouped by area when there are many)
   - the open discussion (threads, pending review comments, unsent drafts)

   The step is done when you can name the commit being reviewed (or "whole PR"), say whether the review is stale, and list the files still unviewed.
4. **Read the code being reviewed** with the read-only commands in [Reading the code](#reading-the-code), then help with what the user asks.

## The review workspace

Everything the plugin does keeps one invariant. The working-copy change `@` (the **review change**) sits on the **diff base**, and the reviewed tree is restored into it:

- **Files on disk** are exactly the reviewed revision (the PR head, or one commit).
- **`@-`** is the diff base: the merge-base of the PR and its base branch, or the commit's parents in commit mode.
- **`jj diff -r @`**, `git diff HEAD` (the repo is colocated, so git's `HEAD` is `@-`) and the user's gitsigns all show exactly the reviewed changes.
- **The PR's own commits** are never the working copy. `@` is a throwaway change that the plugin abandons on cleanup or when it moves.

**Stale review:** `review.stale` means the PR moved on GitHub after the review change was made (`review.head` ≠ `pr.headRefOid`). The files on disk, `files` and `commits` are still at the old head, while threads and `viewed.github` already follow the new one. Name the commits the user hasn't seen yet (`jj log -r '<review.head>..<pr.headRefOid>' --ignore-working-copy`; they are usually already fetched), and tell the user that `:PRRefresh` in Neovim moves the review to the new head.

Modes, from `review.mode` in the dump:

- **`workspace`** (the default): a separate jj workspace at `~/.prr/<repo>-pr-<N>`, named `pr-<N>`.
- **`inplace`**: the review change sits in the user's main workspace. Their previous change is kept and restored on cleanup.

**The review is the user's to steer.** Your job in it is read-only: read with `--ignore-working-copy`, and leave `@`, the PR's commits, bookmarks and remotes as they are. That keeps the Neovim session, whose state is tied to the current `@`, in sync. Any jj or git command that writes would break the invariant:

- `jj new`, `edit`, `squash`, `describe`, `restore`, `abandon`, `rebase`
- `git checkout`, `git commit`, a push

Editing files on disk would mix your edits into the diff the user is reviewing, and they would be abandoned on cleanup. To propose a change, write it as a review comment, ideally a ```` ```suggestion ```` block (see [Comments](#comments)). If the user wants to try code out, do it in a separate workspace or checkout, outside the review workspace.

## Commit mode

The user can review the PR one commit at a time (`<C-t>` toggles, `<C-n>` / `<C-p>` step). The plugin moves between commits by replacing the review change:

- it runs `jj new <commit's parents>` and `jj restore --from <commit>`, then abandons the old review change;
- leaving commit mode does the same with the merge-base and the PR head.

So in commit mode `@-` is the reviewed commit's parent, the files on disk are that commit's tree, and `jj diff -r @` is that commit's changes. For a merge commit, `@` has all its parents, so the diff is only the conflict resolution.

`review.commit_mode` and `review.current_commit` in the dump say where the user is. Only the user moves between commits, from Neovim. To look at another commit, read it in place with `jj diff -r <commit>` or `jj file show -r <commit> <path>`.

Viewed state is per commit: a file counts as viewed for the PR once it is viewed in every commit that changes it.

## Reading the code

All of these are read-only and safe to run while Neovim is open:

- **Reviewed diff:** `jj diff -r @ --git --ignore-working-copy`. Add `--stat`, or a path to narrow it.
- **Whole PR from anywhere:** `jj diff --from <review.merge_base> --to <review.head> --git --ignore-working-copy`.
- **One commit:** `jj diff -r <commit> --git --ignore-working-copy`. For history, `jj log -r '<merge_base>..<head>' --ignore-working-copy`.
- **File at another revision:** `jj file show -r <rev> <path> --ignore-working-copy`.
- **Current files:** read them on disk; they are the reviewed revision.

## Comments

The user is `viewer` (their GitHub login), so their own comments are the ones with `user == viewer`.

- **Threads** are posted review comments. Each has `path`, `line` (in GitHub's PR head), the replies under it, and `original_commit`. An `outdated` thread's line no longer exists in the head: read it at `original_line` in `original_commit`.
- **Pending review** is the user's own unsubmitted GitHub review. Only they can see it, and they submit it from Neovim or github.com.
- **Drafts** are comment text the user typed in Neovim that hasn't reached GitHub: the window was closed with `<Esc>`, or sending it failed (e.g. a network error). Reopening the same comment window brings the text back. `action` is what the text was for: a new line comment (`add_review_comment`, `add_pending`, `add_pending_thread`, `add_*_suggestion`), a PR-level comment (`add_pr_comment`, `reply_global`), a `reply` or an `edit` of the comment `comment_id`, or a review body (`approve_pr`, `request_changes`, `submit_pending`). A draft whose text equals the comment it targets is a leftover, not open work.
- **Conversation** is the PR-level discussion plus review summaries (`state`: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`). Bots (`user` ending in `[bot]`) post deploy notices and automated reviews there; skim past them unless asked.

When you draft a comment for the user, give the file, the line (a line of the reviewed diff) and the body. The user adds it with `:PRPendingComment` (pending) or `:PRLineComment` (posted right away). Anything you post to GitHub yourself is visible to the PR's author, so post only when the user explicitly asks you to.

## Context JSON

`prr context` prints one JSON object. It is read-only: GitHub reads, the plugin's session file, and `jj log --ignore-working-copy`. Optional keys are left out when empty or false (`current_commit`, `outdated`, `drafts`, `errors`, ...).

- `viewer`: the user's GitHub login.
- `pr`: number, url, title, body, author, state, head / base branch, `headRefOid` (GitHub's current head), `reviewDecision`, size.
- `review`: `root`; `change` (the review change: id, parents, description); `mode`; `merge_base`; `head` (the PR head the review was made from); `stale`; `commit_mode`; `current_commit`; `session_saved` (false when the plugin has no session yet, in which case viewed-per-commit and drafts are missing).
- `commits`: the PR's commits up to `review.head`, oldest first: `commit` (full id, as in `current_commit` and `viewed.per_commit`), `change` (jj change id), `subject`, `files` (`<status> <path>`).
- `files`: the PR's changed files at `review.head`, `{ path, status }`.
- `viewed.github`: path to `VIEWED` / `UNVIEWED` / `DISMISSED` (viewed, then changed). This is the authority for the whole PR. `viewed.per_commit` maps a commit id to its viewed paths; use it in commit mode.
- `threads`, `pending_review`, `conversation`, `drafts`: see [Comments](#comments).
- `errors`: the parts that failed to load, if any.
