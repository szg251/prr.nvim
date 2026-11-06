# GitHub PR Reviewer for Neovim

A powerful Neovim plugin for reviewing GitHub Pull Requests directly in your editor. Review PRs with the full power of your development environment - LSP, navigation, favorite files, and all your familiar tools.

![demo](https://i.imgur.com/WsYYVQy.gif)
![menu](https://i.imgur.com/77Tc8HS.png)

## Disclaimer

It is a experimental project and may contain bugs. Use at your own risk.

## Why This Plugin?

**Traditional PR review tools force you into a limited web interface.** This plugin brings PR reviews into your Neovim environment where you have:

- 🚀 **Full LSP support** - Jump to definitions, find references, see type information while reviewing
- 📁 **Your favorite navigation tools** - Use arrow.nvim, harpoon, telescope, or any file navigation plugin
- 🔍 **See the full codebase** - Not limited to just the changed lines - explore the entire context
- ⚡ **Efficient workflows** - Built-in keybindings for navigation and smart change tracking
- 💬 **Comprehensive comment management** - Add, edit, delete, reply to comments with a great UX
- 📝 **Pending comments** - Draft comments locally and submit them all together when you're ready
- 🎯 **Context-aware** - View conversation threads, see file previews, and navigate with ease

**Review faster, review better.** Use the same environment where you write code to review it.

## Features

### Core Review Features
- ✅ **Review PRs locally** - Check out the PR in its own jj workspace (or change)
- ✅ **Session persistence** - Resume reviews after restarting Neovim
- ✅ **Fork PR support** - Automatically handles PRs from forks
- ✅ **Review requests** - List PRs where you're requested as reviewer
- ✅ **Review buffer** - Interactive file browser with foldable directories
- ✅ **Change tracking** - See your progress with floating indicators (toggle on/off)
- ✅ **Works with your git tools** - git's `HEAD` is the diff base, so gitsigns, fugitive and `git diff HEAD` show exactly the PR's changes

### Comment Management
- 💬 **View comments inline** - PR comments appear as virtual text with reactions
- 💬 **Add line comments** - Comment on specific lines with context
- 💬 **Pending comments** - Draft comments locally, submit all at once
- 💬 **List all comments** - Browse all PR comments (posted + pending) with file preview
- 💬 **Reply to comments** - Continue conversation threads
- 💬 **Edit/Delete** - Modify or remove your comments
- 💬 **Comment threads** - View full conversation context when replying
- 👍 **Emoji reactions** - Add/remove GitHub reactions (👍 👎 😄 🎉 😕 ❤️ 🚀 👀) to comments

### Review Actions
- ✓ **Approve PRs** - Submit approval with optional comment
- ✗ **Request changes** - Request changes with explanation
- 📊 **PR Info** - View stats, reviews, merge status, CI checks
- 🌐 **Open in browser** - Quick access to PR on GitHub
- 🎨 **Interactive menu** - `:PR` command for quick access to all features

### UI & Pickers
- 🔍 **Multiple picker support** - Native `vim.ui.select`, Telescope, or fzf-lua
- 🔍 **File previews** - See file content and context when selecting comments
- 🎨 **Smart formatting** - Shows file paths, authors, status, and comment previews
- ⌨️ **Keyboard-driven** - Efficient navigation with configurable keybindings

## Requirements

- Neovim >= 0.11.0
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- [jj (Jujutsu)](https://github.com/jj-vcs/jj) - the repository must be a jj repo; a colocated jj + git repo is needed for git tools (gitsigns, fugitive) to show the diff
- Optional: [bat](https://github.com/sharkdp/bat) for syntax-highlighted previews in fzf-lua

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "otavioschwanck/github-pr-reviewer.nvim",
  opts = {
    -- options here
  },
  keys = {
    { "<leader>p", "<cmd>PRReviewMenu<cr>",    desc = "PR Review Menu" },
    { "<leader>p", ":<C-u>'<,'>PRSuggestChange<CR>", desc = "Suggest change", mode = "v" }
  }
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "otavioschwanck/github-pr-reviewer.nvim",
  config = function()
    require("github-pr-reviewer").setup()

    -- Recommended keymaps
    vim.keymap.set("n", "<leader>p", "<cmd>PRReviewMenu<cr>", { desc = "PR Review Menu" })
    vim.keymap.set("v", "<leader>p", ":<C-u>'<,'>PRSuggestChange<CR>", { desc = "Suggest change" })
  end
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'otavioschwanck/github-pr-reviewer.nvim'

" In your init.vim or init.lua
lua << EOF
  require("github-pr-reviewer").setup()

  -- Recommended keymaps
  vim.keymap.set("n", "<leader>p", "<cmd>PRReviewMenu<cr>", { desc = "PR Review Menu" })
  vim.keymap.set("v", "<leader>p", ":<C-u>'<,'>PRSuggestChange<CR>", { desc = "Suggest change" })
EOF
```

## Configuration

```lua
require("github-pr-reviewer").setup({
  -- Where to review: "workspace" (default) checks the PR out in a separate jj
  -- workspace and :cd's into it; "inplace" creates the review change in the
  -- current workspace
  review_mode = "workspace",

  -- Optional function(repo_root, pr_number) -> path for the review workspace
  -- (default: ~/.prr/<github-repo-name>-pr-<number>)
  workspace_path = nil,

  -- Picker for PR selection: "native", "fzf-lua", or "telescope"
  picker = "native",

  -- Open the first file automatically
  open_files_on_review = true,

  -- Show PR comments as virtual text in buffers
  show_comments = true,

  -- Show icons/emojis in UI (set to false for a text-only interface)
  show_icons = true,

  -- Show floating windows with PR info, stats, and keymaps
  show_floats = true,

  -- Max number of PRs to fetch when listing (default: 30)
  pr_list_limit = 30,

  -- Key to mark file as viewed and go to next file (only works in review mode)
  mark_as_viewed_key = "<CR>",

  -- Key to toggle floating windows visibility (only works in review mode)
  toggle_floats_key = "<C-r>",

  -- Remove the selected review in the :PRReviewSessions picker
  review_sessions_delete_key = "<C-d>",

  -- Commit-based reviewing (only works in review mode)
  commit_mode_toggle_key = "<C-t>",    -- toggle between the whole PR and single commits
  next_commit_key = "<C-n>",           -- next commit (enters commit mode)
  prev_commit_key = "<C-p>",           -- previous commit (enters commit mode)
  sync_viewed_with_github = true,      -- two-way sync of viewed files with GitHub's "Viewed" checkboxes

  -- Key to go to next modified file (only works in review mode)
  next_file_key = "<C-l>",

  -- Key to go to previous modified file (only works in review mode)
  prev_file_key = "<C-h>",
})
```

## Commands

### Main Menu

| Command | Description |
|---------|-------------|
| `:PR` or `:PRReviewMenu` | Show interactive menu with all available actions |

### Review Workflow

| Command | Description |
|---------|-------------|
| `:PRReview` | Select and start reviewing a PR |
| `:PRListReviewRequests` | List PRs where you are requested as reviewer |
| `:PRRefresh` | Fetch the latest PR head and recreate the review change for it |
| `:PRReviewCleanup` | End review, abandon the review change, remove the review workspace (or return to your previous change) |
| `:PRInfo` | Show PR information (stats, reviews, merge status) |
| `:PROpen` | Open PR in browser |
| `:PRReviewSessions` | List open reviews (review workspaces) to open, switch to, or remove (`<C-d>`) |
| `:PRLoadLastSession` | Restore last PR review session (after restarting Neovim) |
| `:PRReviewBuffer` | Toggle review buffer (interactive file browser) |

### Comments

| Command | Description |
|---------|-------------|
| `:PRReviewComment` | Show comments at cursor line (also shows on `CursorHold`) |
| `:PRLineComment` | Add a review comment on the current line |
| `:PRPendingComment` | Add a pending comment (submitted with approval/rejection) |
| `:PRListPendingComments` | List all pending comments and navigate to selected one |
| `:PRListAllComments` | List ALL comments (pending + posted) with file preview |
| `:PRReply` | Reply to a comment on the current line |
| `:PREditComment` | Edit your comment (works for both pending and posted) |
| `:PRDeleteComment` | Delete your comment on the current line |
| `:PRToggleReaction` | Toggle emoji reaction on a comment at the current line |

### Review Actions

| Command | Description |
|---------|-------------|
| `:PRApprove` | Approve the PR (submits pending comments if any) |
| `:PRRequestChanges` | Request changes on the PR (submits pending comments if any) |
| `:PRComment` | Add a general comment to the PR |

## Quick Start

### The `:PR` Menu - Your Review Command Center

**The easiest way to use this plugin is through the interactive `:PR` menu.** Simply type `:PR` and use single-key shortcuts to access all features:

```vim
:PR              " Open the interactive menu
```

From the menu, press:
- `l` - Start reviewing a PR (list all open PRs); when reviews are open, `l` opens the review sessions list (`Resume PR #N` when there is just one) and `p` lists PRs
- `w` - (during a review) Review sessions: switch to another open review
- `r` - List PRs where you're requested as reviewer
- `b` - Toggle review buffer (see all changed files)
- `i` - Show PR info (stats, reviews, CI checks)
- `o` - Open PR in browser
- `R` - Toggle emoji reaction on comment at cursor
- `a` - **Approve** the PR
- `x` - **Request changes** on the PR
- `c` - Cleanup and exit review mode

**No need to memorize commands!** The menu adapts based on whether you're in review mode or not, showing only relevant options.

### Quick Review Workflow (Using the Menu)

1. **Open the menu and start a review:**
   ```vim
   :PR
   " Press 'r' to review a PR, or 'l' to see review requests
   ```

2. **Browse changed files:**
   ```vim
   :PR
   " Press 'b' to open the review buffer
   " Press <CR> on a file to open it
   " Press <CR> on a directory to collapse/expand it
   ```

3. **Navigate with full LSP support:**
   - Use `gd` to jump to definitions
   - Use `gr` to find references
   - Use `K` to see documentation
   - Use Telescope/fzf to search across the codebase
   - **You're not limited to changed lines** - explore the full context!

4. **Add pending comments as you review:**
   - Use `:PRPendingComment` to draft comments
   - All pending comments are saved locally
   - You can continue reviewing multiple files

5. **Finish the review:**
   ```vim
   :PR
   " Press 'a' to approve (submits all pending comments)
   " Or press 'x' to request changes
   " Then press 'c' to cleanup and return to your work
   ```

### Alternative: Direct Commands

While the `:PR` menu is recommended, you can also use direct commands if you prefer:

- `:PRReview` - Start reviewing a PR
- `:PRReviewBuffer` - Toggle review buffer
- `:PRApprove` - Approve the PR
- `:PRReviewCleanup` - Exit review mode

See the [Commands](#commands) section for the full list.

## Usage Guide

### Starting a Review

1. Run `:PRListReviewRequests` to see PRs requesting your review, or `:PRReview` for all open PRs
2. Select a PR from the list
3. The plugin will:
   - Run `jj git fetch` for the PR's base and head branches
   - Create a review change (described `pr-review #<N>: <head> -> <base>`) on the merge-base, with the PR head's files restored into it
   - Fetch all PR comments
   - Open the review buffer with all modified files

There is no need to commit or stash anything first: jj always snapshots your work into its own change, so it is never touched by the review.

The files on disk are exactly the PR head, but the review change's parent is the diff base (the merge-base). In a colocated jj + git repo, git's `HEAD` is therefore the diff base, so git tools show exactly the PR's changes (see [Viewing Diffs](#viewing-diffs)). The PR's commits are never the working copy, so local edits can't rewrite them: they go into the throwaway review change.

### Review Modes

**Workspace mode (default, `review_mode = "workspace"`)**

The PR is checked out in a separate jj workspace:

```bash
jj workspace add --name pr-<N> -r <merge-base> -m "pr-review #<N>: <head> -> <base>" <path>
jj restore --from <pr head>   # in the new workspace
```

Neovim `:cd`s into the workspace, and back to where it came from when the review is cleaned up or put aside. Your original checkout is left untouched (no LSP or file-watcher churn). The workspace path defaults to `~/.prr/<github-repo-name>-pr-<number>` (the repository name from the `origin` remote, falling back to the repo directory's name); override it with `workspace_path`. If a `pr-<N>` workspace already exists (e.g. a review that was never cleaned up) it is reused.

Tradeoff: files jj doesn't track (`node_modules`, `.env`, virtualenvs, ...) are not present in the new workspace, so LSP or builds may not work there. Use inplace mode if you need them.

**Inplace mode (`review_mode = "inplace"`)**

The plugin runs `jj new <merge-base> -m "pr-review #<N>: ..."` and `jj restore --from <pr head>` in the current workspace and remembers the change you were on. On cleanup it goes back to that change with `jj edit` (or `jj new` on its parents if jj auto-abandoned it because it was empty). Your work in progress lives in its own change, so it is never touched.

### Review Requests

Use `:PRListReviewRequests` to see PRs where you've been requested as a reviewer:

- Shows PR info with additions/deletions stats
- **Enter**: Start reviewing the selected PR

### From the Shell: `bin/prr`

`bin/prr` (needs `gh`, `jj` and `fzf`) picks a PR, `cd`s into its review workspace and opens Neovim reviewing it. The terminal's cwd is the review workspace, so e.g. kitty opens new tabs there (over SSH the script reports the cwd to the terminal with OSC 7). Put `bin/` on your `PATH` (or symlink the script).

```sh
prr                # PRs where your review is requested; ctrl-t toggles to all open PRs
prr --all          # start with all open PRs
prr 123            # skip the picker (inside a repo)
prr clean          # remove this repo's review workspaces (directories, review changes, sessions)
prr clean --all    # ... of every repo with a review workspace in ~/.prr, plus leftover directories there
```

Inside a jj repo it lists that repo's PRs. Anywhere else it lists the PRs of every jj repo found up to two levels under `PRR_REPO_DIRS` (colon-separated, default `~/proda:~`), with a repo column, and `cd`s into the picked PR's repo first.

`●` marks PRs that already have a review in progress. A new review workspace is created first by a headless Neovim (`require("github-pr-reviewer").prepare_pr(N)`), then Neovim is started in it with `require("github-pr-reviewer").open_pr(N)` (which you can also call yourself). In inplace mode Neovim starts in the repo root and creates the review change there.

### Review Buffer (Interactive File Browser)

Press `:PRReviewBuffer` or use `b` in the `:PR` menu to open an interactive file browser:

```
┌─ PR #123: Add authentication ─────────────────────┐
│                                                    │
│  ▼ app/auth/                                       │
│    ✓ login.rb                          +45 -12    │
│    ○ session.rb                        +23 -5     │
│  ▶ spec/auth/                                      │
│  ✓ config/routes.rb                    +2 -0      │
│                                                    │
│  Progress: 2/4 files viewed                       │
│  <CR>: Open file | v: Toggle viewed | q: Close    │
└────────────────────────────────────────────────────┘
```

Features:
- **Foldable directories**: Press `<CR>` on a directory to collapse/expand it
  - **▼** = Expanded directory (showing files)
  - **▶** = Collapsed directory (files hidden)
- **✓** = File has been marked as viewed
- **○** = File not yet viewed
- Shows additions/deletions for each file
- Press `<CR>` on a file to open it (`s` / `v` open it in a split / vertical split); double click works too
- Press `m` to mark a file viewed
- Press `q` to close
- Automatically refreshes as you mark files viewed
- The entry under the cursor gets a selection background (`PRReviewSelection`, linked to `CursorLine`); the open file / reviewed commit is bold (`PRReviewCurrent`). Override either with `vim.api.nvim_set_hl`

### Navigating Changes

The plugin includes built-in file navigation that only works during PR review mode (for hunks within a file, use your git tools - see [Viewing Diffs](#viewing-diffs)):

**File Navigation** (between modified files):
- `<C-l>` (default) - Go to next modified file
- `<C-h>` (default) - Go to previous modified file
- `<CR>` (default) - Mark file as viewed and jump to next file

All keybindings are configurable in setup and only activate during PR review mode.

### Commit-Based Reviewing

Instead of the whole PR at once, you can review it one commit at a time:

- `<C-t>` (default) - Toggle between reviewing the whole PR and single commits; the sidebar follows (file list for the whole PR, commit tree in commit mode)
- `<C-n>` / `<C-p>` (default) - Next / previous commit (from PR mode they start at the first / last commit)

In commit mode the review change is recreated on the commit's parents with the commit's files restored
into it (`jj new <parents>` + `jj restore --from <commit>`), so the files on disk are exactly the commit's
version and git tools show only that commit's changes. Going back to the whole PR does the same with the
merge-base and the PR head. Merge commits are listed against their auto-merged parents, so the file list
only shows conflict resolutions, while git's `HEAD` is the first parent, so git tools show the merge
against its first parent. The file list, file navigation and floats show the current commit.

In commit mode the sidebar shows the PR's commits (oldest first), identified by their jj change id (unique prefix highlighted like `jj log`, `PRReviewChangeIdPrefix` / `PRReviewChangeIdRest`), with viewed progress; the current commit is
expanded to its files. `<CR>` on a commit enters it (on the current one: fold/unfold), `<CR>` on a file
enters its commit and opens it, `m` toggles viewed for a file or for a whole commit.

**Viewed state is per commit.** Marking a file viewed in commit mode only covers that commit's changes to
it. The file counts as viewed for the whole PR once it is viewed in every commit that changes it.
Marking a file viewed in PR mode marks it in all of its commits. Viewed state is stored per commit SHA, so
after a force-push the rewritten commits start unviewed; new commits on top only reset the files they touch.

**Viewed state is synced with GitHub** (`sync_viewed_with_github`). GitHub's "Viewed" checkbox is per file for
the whole PR, so it follows the PR-level state: a file is marked viewed on GitHub once it is viewed in every
commit that changes it, and unmarked as soon as it isn't. When a review starts, is restored or refreshed
(`:PRRefresh`), the GitHub state wins: files viewed there are viewed in all their commits, files not viewed
there (unmarked, or changed since they were viewed) are unmarked in all of them.

**Comments in commit mode** show only the comments made on that commit, at their line in that commit.
New single comments are attached to that commit; pending (batched) comments are only available in PR mode,
because a GitHub review is submitted against a single commit.

Unsaved edits in review buffers are discarded when switching commits.

### Viewing Diffs

The plugin doesn't draw diffs itself. Because git's `HEAD` in the review checkout is the diff base, your git tools show exactly the PR's changes (or the current commit's in commit mode):

- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) - signs, `]c` / `[c` hunk navigation, `:Gitsigns preview_hunk`
- [vim-fugitive](https://github.com/tpope/vim-fugitive) - `:Gvdiffsplit` for a side-by-side diff
- `git diff HEAD` in a terminal

This requires a colocated jj + git repo (workspace mode creates a git worktree for the review workspace when the repo is colocated). Deleted files can't be shown by git tools from the file list, so the plugin opens them as a read-only `<path> [DELETED]` buffer with the base content.

### Change Progress Indicator

When reviewing a file of the PR, you'll see three floating windows providing context:

```
┌──────────────────┐
│ 📁 File 2/5      │
└──────────────────┘
┌──────────────────┐
│ ✓ Viewed         │
│ +15 ~3 -8        │
│ 💬 2 comments    │
└──────────────────┘
┌──────────────────────┐
│ <C-l>: Next file     │
│ <C-h>: Prev file     │
│ <CR>: Mark viewed    │
│ <C-r>: Toggle floats │
│ ...                  │
└──────────────────────┘
```

**General Float**:
- **File position**: File x/total (plus Commit i/n in commit mode)

**Buffer Float**:
- **Viewed status**: Shows if the current file has been marked as viewed
- **Stats**: +additions ~modifications -deletions
- **Comments**: 💬 Number of PR comments in this file

**Keymaps Float**:
- Shows available keyboard shortcuts for review mode (`<CR>` marks the file as viewed and jumps to the next file)

**Toggle Floating Windows**:
- Press `<C-r>` (default) to hide/show all three floating windows
- Set `show_floats = false` in config to disable them by default
- Useful when you want a cleaner view or need more screen space

### Pending Comments Workflow

One of the most efficient ways to review is using **pending comments**:

1. As you review, add pending comments with `:PRPendingComment`
2. These are saved locally (not submitted to GitHub yet)
3. Continue reviewing, adding more pending comments
4. Use `:PRListPendingComments` to review all your draft comments
5. When ready, run `:PRApprove` or `:PRRequestChanges`
6. The plugin shows a preview of ALL pending comments before submission
7. Confirm to submit your review + all pending comments at once

Benefits:
- Draft your thoughts as you review without interrupting your flow
- Review all your comments before submitting
- Submit everything together as a cohesive review
- Edit or delete pending comments before submission

### Viewing and Managing Comments

**Add Comments:**
- `:PRLineComment` - Add a review comment on the current line (submitted immediately)
- `:PRPendingComment` - Add a pending comment (submitted with approval/rejection)
- `:PRComment` - Add a general PR comment

**View Comments:**
- Comments appear as virtual text on lines automatically
- `:PRReviewComment` - Show comments at cursor line in a popup
- `:PRListAllComments` - Browse ALL comments with file preview

**Manage Comments:**
- `:PRReply` - Reply to a comment (cannot reply to pending comments)
- `:PREditComment` - Edit your comment (works for both pending and posted)
- `:PRDeleteComment` - Delete your comment
- `:PRToggleReaction` - Add or remove an emoji reaction to a comment

**React to Comments:**
- Position cursor on a line with a comment
- Use `:PRToggleReaction` or press `R` in the `:PR` menu
- Select an emoji (👍 👎 😄 🎉 😕 ❤️ 🚀 👀)
- Selecting the same reaction again removes it (toggle behavior)
- Reactions appear inline next to comment indicators and in comment previews

**List All Comments** (`:PRListAllComments`):
- Shows both pending and posted comments
- Includes author, file path, line number
- **Telescope**: Full file preview with syntax highlighting and comment highlighted
- **fzf-lua**: File preview with bat/cat showing context around the comment
- Navigate to comment location on selection

### Session Persistence

The plugin automatically saves your review session state:

- **Auto-save**: Session is saved when you start a review
- **Per PR**: Each PR has its own session, keyed by the shared jj repo store (`<root>/.jj/repo`) and the PR number, so sessions are found from any workspace of the repo
- **What's saved**: PR number, review mode, review root, main root, workspace name, merge base, review change, previous change, modified files, viewed status, pending comments
- **Auto-cleanup**: Session file is deleted when you run `:PRReviewCleanup`

To restore a session after restarting Neovim:

```vim
:PRLoadLastSession
```

**Review sessions:** `:PRReviewSessions` (`l` in the `:PR` menu, `w` during a review) lists every open review of the repository: each workspace whose working copy is a `pr-review #<N>` change (found with `jj workspace list`), including an inplace review in the default workspace. The review of the current workspace comes first; each entry shows whether a saved session exists. Picking one restores its session (or starts its review again in that workspace if it has none). If you are reviewing another PR, that review is put aside first: its session is saved and Neovim `:cd`s out, but its workspace stays, so you can switch back later. `<C-d>` (`review_sessions_delete_key`) in the picker removes the selected review: its workspace (or inplace review change) and session. With a single open review and nothing loaded, it is resumed directly.

`:PRLoadLastSession` first looks at the current directory: if it is a review workspace, it resumes that PR, even if another PR's session is newer. If the PR has no saved session, its review is started again in that workspace. Anywhere else, the most recently saved session of the repo is restored.

In workspace mode, restoring a session `:cd`s into the review workspace.

Session files are stored in `~/.local/share/nvim/github-pr-reviewer-sessions/`.

### Finishing the Review

1. Run `:PRApprove` to approve, or `:PRRequestChanges` to request changes
   - If you have pending comments, they'll be shown for confirmation
   - All pending comments are submitted with your review
   - After approving, you're asked whether to exit the review; yes runs the cleanup below
2. Run `:PRReviewCleanup` to:
   - **Workspace mode**: wipe the workspace's buffers, `:cd` back to where you came from and run `jj workspace remove pr-<N>` (deletes the directory and its git worktree)
   - **Inplace mode**: return to the change you were on before the review
   - Abandon the review change
   - Clear the session

If you start a new review and choose "continue without cleanup", the old workspace stays on disk. Remove it with `jj workspace remove pr-<N>`.

## Complete Workflow Example

Here's a complete workflow for reviewing a PR efficiently:

```vim
" 1. See review requests
:PRListReviewRequests
" Select PR #42 from the list

" 2. Open the review buffer to see all files
:PRReviewBuffer

" 3. Jump to a file by pressing <CR>

" 4. Navigate with full LSP support
gd              " Go to definition
gr              " Find references
K               " See documentation

" 5. Use your favorite navigation tools
" - Telescope to search across files
" - Arrow/harpoon to mark important files
" - Normal Neovim navigation

" 6. Add pending comments as you review
:PRPendingComment
" Type your comment, press <C-s> to save locally

" 7. Mark file as viewed and go to next
<CR>            " Configured key to mark as viewed

" 8. Continue reviewing other files
<C-l>           " Next file
<C-h>           " Previous file

" 9. List all your pending comments to review them
:PRListAllComments

" 10. Approve and submit all pending comments at once
:PRApprove
" Review the preview, confirm to submit

" 11. Clean up and return to your work
:PRReviewCleanup
```

## Recommended Keymaps

```lua
-- Quick menu access
vim.keymap.set("n", "<leader>p", ":PR<CR>", { desc = "PR Review Menu" })

-- Review workflow
vim.keymap.set("n", "<leader>pr", ":PRReview<CR>", { desc = "Start PR review" })
vim.keymap.set("n", "<leader>pl", ":PRListReviewRequests<CR>", { desc = "List review requests" })
vim.keymap.set("n", "<leader>pc", ":PRReviewCleanup<CR>", { desc = "Cleanup PR review" })
vim.keymap.set("n", "<leader>pi", ":PRInfo<CR>", { desc = "Show PR info" })
vim.keymap.set("n", "<leader>po", ":PROpen<CR>", { desc = "Open PR in browser" })
vim.keymap.set("n", "<leader>pb", ":PRReviewBuffer<CR>", { desc = "Toggle review buffer" })

-- Comments
vim.keymap.set("n", "<leader>pC", ":PRLineComment<CR>", { desc = "Add line comment" })
vim.keymap.set("n", "<leader>pP", ":PRPendingComment<CR>", { desc = "Add pending comment" })
vim.keymap.set("n", "<leader>pv", ":PRListAllComments<CR>", { desc = "List all comments" })
vim.keymap.set("n", "<leader>pp", ":PRListPendingComments<CR>", { desc = "List pending comments" })
vim.keymap.set("n", "<leader>pR", ":PRReply<CR>", { desc = "Reply to comment" })
vim.keymap.set("n", "<leader>pe", ":PREditComment<CR>", { desc = "Edit my comment" })
vim.keymap.set("n", "<leader>pd", ":PRDeleteComment<CR>", { desc = "Delete my comment" })
vim.keymap.set("n", "<leader>pE", ":PRToggleReaction<CR>", { desc = "Toggle emoji reaction" })

-- Review actions
vim.keymap.set("n", "<leader>pa", ":PRApprove<CR>", { desc = "Approve PR" })
vim.keymap.set("n", "<leader>px", ":PRRequestChanges<CR>", { desc = "Request changes" })
```

## Integration with Other Plugins

### arrow.nvim / harpoon

Mark files you want to return to during review:

```lua
-- With arrow.nvim
require("arrow").setup()

-- With harpoon
require("harpoon").setup()
```

Both plugins work seamlessly during PR review, letting you mark important files and jump between them quickly.

### LSP (Native Neovim LSP or nvim-lspconfig)

Your LSP is fully functional during PR review:
- `gd` - Go to definition
- `gr` - Find references
- `K` - Hover documentation
- `<leader>rn` - Rename
- All your LSP keybindings work normally

**This is a huge advantage over web-based PR review** - you can explore the full codebase with full language intelligence.

### Telescope / fzf-lua

Set your preferred picker in the config:

```lua
require("github-pr-reviewer").setup({
  picker = "telescope",  -- or "fzf-lua" or "native"
})
```

Telescope and fzf-lua provide enhanced comment browsing with file previews.

### gitsigns.nvim / vim-fugitive (Recommended)

The plugin has no built-in diff view; gitsigns is the recommended way to see the PR's hunks. In a colocated jj + git repo, git's `HEAD` in the review checkout is the diff base (and the git index matches it), so with a default setup gitsigns shows exactly the PR's changes (or the current commit's in commit mode):

```lua
require("gitsigns").setup({
  -- your gitsigns config
})

-- Hunk navigation and preview
vim.keymap.set("n", "]c", function() require("gitsigns").nav_hunk("next") end)
vim.keymap.set("n", "[c", function() require("gitsigns").nav_hunk("prev") end)
vim.keymap.set("n", "<leader>hp", function() require("gitsigns").preview_hunk() end)
```

With vim-fugitive, `:Gvdiffsplit` shows the current file side by side with the diff base.

## How It Works

1. **Starting review**: Runs `jj git fetch` (only the base branch from `origin` and the head branch from `origin` or the fork remote), then creates a review change on the merge-base and restores the PR head's files into it (`jj restore --from <pr head>`) - in a new jj workspace (workspace mode) or in the current one (inplace mode). Git's `HEAD` is thus the diff base, so git tools show the PR's changes. A review change is identified by its description starting with `pr-review #<N>`.

2. **Fork support**: Automatically detects fork PRs using GitHub's `isCrossRepository` field, adds a `fork-<owner>` remote with `jj git remote add`, and fetches only the PR head branch from it.

3. **Comments**: Fetches PR comments via GitHub API and displays them as virtual text. Comments are cached per buffer for performance.

4. **Pending comments**: Stored locally in session files (JSON format) and submitted to GitHub when you approve/request changes.

5. **Change tracking**: Diffs are computed against the merge-base of the PR head and the base branch (`heads(::head & ::base@origin)`) - the same base GitHub's "Files changed" tab uses, so changes that only landed on the base branch don't show up. The file list comes from `jj diff --from <merge-base> --to @` (renames are shown as a delete + an add). Base file content comes from `jj file show -r <merge-base>`, and changed lines are computed with `vim.diff` between that content and the file on disk (used for the sidebar stats, to check that line comments are on changed lines, and to jump to the first change when a file is opened).

6. **Refresh**: `:PRRefresh` re-fetches, recreates the review change for the new PR head (in the same workspace in workspace mode) and abandons the old one. Local edits made in the review change are discarded.

7. **Cleanup**: Abandons the review change and either removes the review workspace (workspace mode) or goes back to the change you were on (inplace mode).

## Troubleshooting

### "Not on a review change"

You can only run `:PRReviewCleanup` while in a review, i.e. when the current change's description starts with `pr-review #<N>`.

### Comments not showing

1. Make sure `show_comments = true` in your config
2. Check that you're authenticated with `gh auth status`
3. Try `:PRReviewComment` to manually show comments at cursor

### PR actions failing

Ensure GitHub CLI is properly authenticated:

```bash
gh auth status
gh auth login  # if not authenticated
```

### Fetch failed

If `jj git fetch` fails, you might have old fork remotes that are no longer accessible. Clean them up:

```bash
jj git remote list
jj git remote remove fork-<owner>
```

### Leftover review workspaces

If a review was never cleaned up (e.g. you chose "continue without cleanup"), its workspace stays on disk. List and remove it with:

```bash
jj workspace list
jj workspace remove pr-<N>
```

### Preview not working in fzf-lua

Install [bat](https://github.com/sharkdp/bat) for syntax-highlighted previews:

```bash
# macOS
brew install bat

# Ubuntu/Debian
apt install bat

# Arch
pacman -S bat
```

If `bat` is not available, the plugin falls back to `cat`.

## Performance

The plugin is designed for performance:

- **Lazy loading**: Comments are only fetched when entering a buffer
- **Caching**: Comments are cached per buffer to avoid repeated API calls
- **Efficient diff parsing**: Only parses diff output once per file
- **Background jobs**: File operations use async jobs when possible
- **Session files**: Small JSON files for fast load/save

Typical startup time: <100ms for a PR with 20+ files.

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Created by [Otávio Schwanck]

Inspired by the need for a better PR review experience in Neovim.

Special thanks to the Neovim community and all contributors!
