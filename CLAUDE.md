# Claude Code - Guide for AIs and Developers

This document contains essential information about the architecture, patterns, and important details of the `neovim-pr-reviewer` plugin.

## Overview

Neovim/Lua plugin for reviewing GitHub Pull Requests directly in the editor, with support for:
- Navigation between modified files
- Diff data for stats, comment validation and first-change jumps (display is left to git tools)
- Comment system (inline and global)
- PR approval/rejection
- Marking files as "viewed"

## Main Architecture

### Main File
- **`lua/github-pr-reviewer/init.lua`** (~5700 lines): Contains all plugin logic

### Auxiliary Modules
- **`lua/github-pr-reviewer/github.lua`**: GitHub GraphQL API interaction
- **`lua/github-pr-reviewer/ui.lua`**: UI components (pickers, menus)
- **`lua/github-pr-reviewer/jj.lua`**: jj (Jujutsu) interaction - fetch, review workspace/change creation, cleanup, changed files, base content (replaces the old `git.lua`)

## Important Concepts

### 1. Diff Data, Not Diff Display

The plugin does NOT draw diffs (no inline diff, no change signs, no split view, no hunk navigation). The review change sits on the diff base with the reviewed content restored into it (see [Review Model](#review-model)), so in a colocated jj + git repo git's `HEAD` is the diff base and gitsigns / fugitive / `git diff HEAD` show exactly the reviewed changes.

The plugin only computes diff DATA:
- `diff_for_file(path)` (`jj.diff_file` against the merge-base, or `jj.diff_commit_file` in commit mode) → `get_changed_lines_for_file()` → `M._buffer_changes[bufnr]` / `M._buffer_hunks[bufnr]` (set by `load_changes_for_buffer`). Used by `is_line_in_diff()` (line comments must be on changed lines) and by the first-change jump on `BufEnter`.
- `get_inline_diff()` is only used by `collect_pr_files()` to compute the sidebar's `+added ~modified -deleted` stats (`file.stats`).

### 2. Buffer System

#### Special Buffers
- **`<path> [DELETED]`**: Read-only scratch buffer with the base content of a deleted file (git tools can't show it from the file list)
- **Review Buffer**: Special buffer with list of modified files (or the commit tree)

#### Buffer State Tracking
```lua
M._buffer_changes[bufnr] = lines      -- Changed line numbers (comment validation)
M._buffer_hunks[bufnr] = hunks        -- Change hunks (first-change jump)
M._buffer_comments[bufnr] = comments  -- Comments in buffer
M._buffer_jumped[bufnr] = bool        -- Whether already jumped to first change
M._buffer_keymaps_saved[bufnr] = bool -- Whether keymaps already configured
```

`load_changes_for_buffer` installs the buffer-local `mark_as_viewed_key` and `toggle_floats_key` maps for every file of the review (not only files with changes).

### 3. Floating Windows (Popups)

Three floating windows displayed on the right (`update_changes_float()`):
1. **General Info**: File X/Total (+ Commit i/n in commit mode)
2. **Buffer Info**: Viewed status, stats (from `file.stats`), comment count
3. **Keymaps**: Available shortcuts

### 4. Navigation System

`<C-l>`/`<C-h>` go to the next/previous file via `open_file_safe(file)` (`edit`). **Important flag**: `M._opening_file` (prevents concurrent opens). Hunk navigation is left to git tools (e.g. gitsigns `]c`/`[c`).

## Patterns and Conventions

### 1. Namespace IDs
```lua
local ns_id = vim.api.nvim_create_namespace("pr_review_comments")  -- comment decorations
```
`ns_id` is the only namespace for buffer decorations (plus `pr_review_deleted_file` for `[DELETED]` buffers). Don't add diff highlights/signs: that's the git tools' job.

### 2. State Cleanup

Clear the comments namespace before re-rendering comments:
```lua
vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
```

### 3. Timing and Scheduling

Use `vim.defer_fn()` when you need Vim to process something first:
- After `edit` command (50ms)
- After creating buffers (50-100ms)
- After layout changes

Use `vim.schedule()` for operations that should run in the next event loop.

### 4. Validity Checks

**ALWAYS check if buffers/windows are valid before using**:
```lua
if vim.api.nvim_buf_is_valid(bufnr) then
  -- safe to use
end

if vim.api.nvim_win_is_valid(winnr) then
  -- safe to use
end
```

## Data Flow

### 1. Review Initialization

```
User: :PR <number>
  ↓
M._start_review_for_pr(pr) → M._do_start_review(pr)
  ↓
jj.checkout_pr()   # jj git fetch + (workspace add | jj new) on merge-base + jj restore --from <pr head>
  ↓
set_review_location(state)  # vim.g.pr_review_root, jj.cwd, ...
open_review_tab(root)       # workspace mode only (tabnew + tcd)
  ↓
collect_pr_files()  # jj.changed_files(merge_base) + stats
  ↓
- Create review buffer with file list
- Populate M._review_files
- Setup autocmds (BufEnter, CursorMoved, etc)
```

### 2. File Opening

```
User: <CR> in review buffer OR C-l/C-h
  ↓
open_file_safe(file)
  ↓
vim.cmd("edit " .. file_path)
  ↓
BufEnter autocmd:
  - load_comments_for_buffer()
  - load_changes_for_buffer()      # Changed lines/hunks + buffer keymaps
  - refresh_review_buffer()
  - jump to first change (first time)
  ↓
update_changes_float()  # Show popups
```

## Important Autocmds

### BufEnter
```lua
1. Load comments
2. Load changes (changed lines/hunks, buffer keymaps)
3. Update review buffer highlight
4. Jump to first change (first time)
```

### CursorMoved
```lua
update_changes_float()
```

### WinLeave
```lua
-- Close floats when leaving window
close_float_wins()
```

## jj Integration

All VCS work goes through `jj.lua`; there are no git commands, branches, stashes or uncommitted-changes checks (jj snapshots the user's work into its own change).

### Review Model

A **review change** is a change whose description starts with `pr-review #<N>` (`jj.current_review_pr()` detects it). `M.config.review_mode` picks where it lives:

- **`"workspace"` (default)**: `jj workspace add --name pr-<N> -r <merge-base> -m "pr-review #<N>: <head> -> <base>" <path>` then `jj restore --from <pr head>` in it (path from `M.config.workspace_path` or `<repo_root>/../<repo>-pr-<N>`). The review opens in its own tab (`open_review_tab()`: `tabnew` + `tcd`). An existing `pr-<N>` workspace is reused. Cleanup wipes the workspace's buffers, closes the tab, runs `jj workspace remove pr-<N>` and abandons the review change.
- **`"inplace"`**: `jj new <merge-base> -m "pr-review #<N>: ..."` + `jj restore --from <pr head>` in the current workspace; the previous change is kept in `vim.g.pr_review_previous_change`. Cleanup does `jj edit` back to it (or `jj new` on its parents if it was auto-abandoned) and abandons the review change.

The review change is on the diff base with the reviewed tree restored into it: files on disk are exactly the PR head, but git's `HEAD` (and index) in a colocated repo is the diff base, so git tools show the PR's changes. The PR's commits are never the working copy, so edits can't rewrite them. The review change is non-empty while reviewing (it holds a copy of the diff) and is abandoned on cleanup / when switching commits. Workspace mode gets a git worktree when the repo is colocated.

Fetching: `jj git fetch` only the base branch from `origin` and the head branch from `origin` or a `fork-<owner>` remote (added with `jj git remote add` for fork PRs).

`M.refresh_pr_branch()` re-fetches, recreates the review change for the new head (same workspace in workspace mode) and abandons the old one.

### Review Location (paths and cwd)

- `set_review_location(state)` stores `vim.g.pr_review_mode/root/main_root/workspace/merge_base/change` and sets **`jj.cwd = state.root`**, so every jj command runs in the review root.
- **`review_root()` / `review_path(path)`** (init.lua) build PR file paths from `vim.g.pr_review_root`, NOT `vim.fn.getcwd()`. Always use them for PR file paths - the cwd is not the review root outside the review tab.
- Sessions are stored per PR (`session_prefix()` = shared repo store `<root>/.jj/repo`, plus `_pr<N>`). `find_session()` prefers the PR whose review change is checked out in the current directory (`jj.current_review_pr(cwd)`), else the most recently saved session; `load_last_session` starts a fresh review of that PR when it has no session file. Open reviews are listed by `M.review_sessions()` from `jj.review_workspaces()` (workspaces whose `@` description starts with `pr-review #`); switching uses `M._unload_review()` (save session, close tab, `reset_review_state()`, workspace kept), removal `M._remove_review_session()` (`jj.cleanup_review` + session delete). `restore_session()` / `resume_without_session()` are shared with `load_last_session`.

### Diff Base (merge-base)

Diffs are against the merge-base of the PR head and the base branch: `heads(::head & ::base@origin)` (same base as GitHub's "Files changed"; base-only changes don't show). Stored in `vim.g.pr_review_merge_base`.

- **File list**: `jj diff --from <merge-base> --to @` with a template. Renames appear as delete + add; there is no "untracked" status.
- **Changed lines**: zero-context diffs - `jj.diff_file` (`vim.diff` between the merge-base content and the file on disk) or, in commit mode, `jj.diff_commit_file` (`jj diff --git -r <commit>`) - data only, see [Diff Data, Not Diff Display](#1-diff-data-not-diff-display).

### Commit Mode (commit-based reviewing)

- `M._commits` (from `jj.pr_commits(merge_base, head)`: oldest first, each `{ id, short, subject, parent, is_merge, files }`) is loaded by `load_commits()` at review start, refresh and session restore. `vim.g.pr_review_head` holds the PR head commit.
- `M.goto_commit(id)` runs `jj.move_review_change(commit.parents, commit.id, desc)` (`jj new <parents>` + `jj restore --from <commit>` + abandon the old review change, so git's `HEAD` is the commit's parent), sets `M._commit_mode`/`M._current_commit` and calls `reload_review_view()`, which re-reads buffers under the review root, rebuilds the file list and reopens the file. `M.exit_commit_mode()` does the same with `{ merge-base }` and the PR head.
- Merge commits: the file list shows only conflict resolutions (`jj diff -r` against the auto-merged parents), while git's `HEAD` is the first parent, so git tools show the merge against its first parent.
- Use `current_commit()`, `diff_base_rev()` (merge-base or the commit's parent) and `diff_for_file()` (`jj.diff_file` vs `jj.diff_commit_file`) instead of reading `vim.g.pr_review_merge_base` directly.
- Viewed state: `M._viewed_commit_files[commit_id][path]`, with `M._viewed_files[path]` derived (viewed in every commit touching it, see `sync_pr_viewed`). Always go through `is_file_viewed()` / `set_file_viewed()`.
- The sidebar follows the review mode: `render_review_buffer()` shows the file list in PR mode and `render_commit_sidebar()` (storing `{ is_commit }` / `{ is_commit_file }` items in `pr_file_map`) in commit mode. There is no separate sidebar toggle.
- Comments: in commit mode only comments with `original_commit_id == current commit` are shown at `original_line`; `github.comment_commit_id` makes new single comments target that commit; pending comments are blocked.

### Fetching Base Content

`jj file show -r <rev> <file>` (`jj.file_lines_at_async`), with `rev = diff_base_rev()` (merge-base, or the commit's parent in commit mode).

### Archived Files (Deleted)

Status "D" (deleted):
- Opened as a read-only `<path> [DELETED]` scratch buffer with the base content
- All lines with DiffDelete highlight (`pr_review_deleted_file` namespace)

### New Files

Status "A" (added): base content = empty, every line counts as changed.

## Available Commands

### Main
- `:PR <number>` - Start review
- `:PRApprove` - Approve PR
- `:PRReject` - Reject PR
- `:PRInfo` - Show PR information
- `:PRMenu` - Interactive menu

### Comments
- `:PRAddComment` - Add line comment
- `:PRAddPendingComment` - Pending comment (not published)
- `:PRSubmitPendingComments` - Publish pending comments
- `:PRListAllComments` - List all comments

### Navigation
- Keybinds (configurable):
  - `<C-l>` / `<C-h>` - Next/prev file
  - `<C-r>` - Toggle floats
  - `<CR>` - Mark as viewed and next
  - `<C-t>` / `<C-n>` / `<C-p>` - Commit mode toggle (also switches the sidebar) / next / prev commit

## Configuration

### Structure
```lua
M.config = {
  show_floats = true,
  next_file_key = "<C-l>",
  prev_file_key = "<C-h>",
  mark_as_viewed_key = "<CR>",
  toggle_floats_key = "<C-r>",
  -- ... more options
}
```

### Highlight Groups

Defined in setup by `define_highlights()` (with `default = true`, re-applied on `ColorScheme`):
```lua
- PRReviewSelection (links to CursorLine) -- sidebar entry under the cursor, all lines of a wrapped entry (update_sidebar_selection)
- PRReviewCurrent (bold)                  -- open file / reviewed commit in the sidebar
```

## Debugging Tips

### 1. Check Current State
```lua
:lua print(vim.inspect(require('github-pr-reviewer')._buffer_changes[vim.api.nvim_get_current_buf()]))
:lua print(vim.inspect(require('github-pr-reviewer')._buffer_hunks[vim.api.nvim_get_current_buf()]))
```

### 2. Check What Git Sees
```bash
git log -1 HEAD     # should be the diff base (merge-base, or the commit's parent)
git diff HEAD       # should be exactly the reviewed changes
```

### 3. Check Namespaces
```lua
:lua vim.api.nvim_buf_clear_namespace(0, -1, 0, -1)  -- Clear everything
```

### 4. Reload Plugin
```lua
:luafile lua/github-pr-reviewer/init.lua
```

## Testing

### Important Test Cases

1. **Git tools see the diff**
   - Start a review (colocated repo), open a file
   - gitsigns signs / `]c` / `:Gvdiffsplit` show exactly the PR's changes
   - In commit mode, only the current commit's changes

2. **File Navigation**
   - C-l/C-h to navigate, first-change jump on first open
   - Floats appear for every review file

3. **Special Files**
   - New file (status A)
   - Deleted file (status D) - `[DELETED]` buffer with previous version
   - Renamed file - verify correct paths

4. **Comments**
   - Line comment on a changed line works; on an unchanged line it's rejected
   - Comments in commit mode attach to the current commit

## Gotchas and Pitfalls

### ❌ DON'T DO

1. **Modify diffopt globally without restoring**
   ```lua
   -- WRONG:
   vim.o.diffopt = "internal,filler,iwhite"  -- Can break diff!

   -- RIGHT:
   -- Use user's diffopt without modifying
   ```

2. **Draw diffs in buffers** - no diff extmarks/signs/split views; git tools display the diff.

3. **Make the PR's commits the working copy** (`jj new <pr head>` / `jj edit <commit>`) - git's `HEAD` would no longer be the diff base, and edits could rewrite the PR's commits.

4. **Don't check validity before using**
   ```lua
   -- WRONG:
   vim.api.nvim_win_close(win, true)  -- Can error if window already closed

   -- RIGHT:
   if vim.api.nvim_win_is_valid(win) then
     vim.api.nvim_win_close(win, true)
   end
   ```

5. **Iterate windows of all tabs (`nvim_list_wins()`)**
   ```lua
   -- WRONG:
   for _, win in ipairs(vim.api.nvim_list_wins()) do ...

   -- RIGHT (the review lives in its own tab in workspace mode):
   for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do ...
   ```

6. **Build PR file paths from getcwd()** - use `review_path(path)` / `review_root()`.

7. **Run mutating jj commands in parallel** - only read-only jj commands (`jj file show`, `jj log`, ...) may run concurrently, and they must pass `--ignore-working-copy` so they don't snapshot the working copy or race on it.

### ✅ ALWAYS DO

1. **Keep the review change on the diff base** (`jj new <base>` + `jj restore --from <reviewed rev>`)
2. **Check buffer/window validity**
3. **Use defer_fn after layout operations**
4. **Test with new (A), deleted (D), and modified (M) files**
5. **Test both `review_mode = "workspace"` and `"inplace"`**

## Performance

### Implemented Optimizations

1. **Viewed files cache**: `M._viewed_files`
2. **Comments cache per buffer**: `M._buffer_comments`
3. **Saved keymaps per buffer**: `M._buffer_keymaps_saved` (avoids recreation)
4. **Update throttling**: `vim.defer_fn` with appropriate delays

### Areas for Improvement

- Load comments lazily (only when needed)
- Cache `jj file show` results
- Debounce update_changes_float on CursorMoved

## Contributing

### Checklist for New Features

- [ ] Works in PR mode and commit mode?
- [ ] Works in workspace and inplace mode?
- [ ] Doesn't add diff decorations to buffers?
- [ ] Tests with A/D/M files?
- [ ] Tests manual navigation (`:b`)?
- [ ] Floats continue working?

### Checklist for Bug Fixes

- [ ] Identified the root cause?
- [ ] Verified it doesn't break other modes?
- [ ] Added validity checks?
- [ ] Tested edge cases (new file, deleted)?
- [ ] Documented the fix?

## Recent Changelog

### 2026 - Git tools show the diff

- ✅ Review change created on the diff base with the reviewed content restored (`jj new <base>` + `jj restore --from <rev>`), so git's `HEAD` is the diff base and gitsigns / fugitive / `git diff HEAD` show the PR's (or commit's) changes
- ✅ Removed the plugin's own diff display: inline diff (`show_inline_diff`), `│` change signs, split view (`diff_view_toggle_key`, `[BEFORE]` buffers, `fix_vsplit`), hunk navigation (`next_hunk_key`/`prev_hunk_key`) and hints

## Contact and Support

- GitHub Issues: https://github.com/username/neovim-pr-reviewer/issues
- Documentation: `:h github-pr-reviewer`

---

**Last updated**: October 2026
**Plugin Version**: 0.1+
