local M = {}

local github = require("github-pr-reviewer.github")
local jj = require("github-pr-reviewer.jj")
local ui = require("github-pr-reviewer.ui")

M.config = {
  review_mode = "workspace",      -- "workspace": review in a separate jj workspace (Neovim :cd's into it)
                                  -- "inplace": review change in the current workspace
  workspace_path = nil,           -- fun(repo_root, pr_number) -> path; default: ~/.prr/<github-repo>-pr-<n>
  picker = "native",              -- "native", "fzf-lua", "telescope"
  open_files_on_review = true,    -- open modified files after starting review
  show_comments = true,           -- show PR comments in buffers during review
  comment_indicator_position = "right_align", -- comment count on commented lines: "right_align" (window edge) or "eol"
  show_icons = true,              -- show icons in UI elements
  show_floats = true,             -- show floating windows with info, stats and keymaps
  debug = false,                  -- show debug messages
  pr_list_limit = 30,             -- max PRs to fetch when listing
  mark_as_viewed_key = "<CR>",    -- key to mark file as viewed and go to next file
  next_file_key = "<C-l>",        -- key to go to next modified file
  prev_file_key = "<C-h>",        -- key to go to previous modified file
  toggle_floats_key = "<C-r>",    -- toggle floating windows visibility
  review_sessions_delete_key = "<C-d>", -- remove the selected review in the review sessions picker
  commit_mode_toggle_key = "<C-t>",    -- toggle between the whole PR (file sidebar) and single commits (commit sidebar)
  next_commit_key = "<C-n>",           -- go to next commit (enters commit mode)
  prev_commit_key = "<C-p>",           -- go to previous commit (enters commit mode)
  sync_viewed_with_github = true,      -- two-way sync of the viewed state with GitHub's "Viewed" checkboxes

  -- Review buffer settings
  review_buffer = {
    position = "left",            -- "left", "right", "top", "bottom"
    width = 50,                   -- width for left/right
    height = 20,                  -- height for top/bottom
    group_by_directory = true,    -- group files by directory
    sort_by = "path",             -- "path", "status", "changes"
    filter_viewed_key = "fv",     -- filter: show only viewed
    filter_not_viewed_key = "fn", -- filter: show only not viewed
    filter_all_key = "fa",        -- filter: show all
    open_split_key = "s",         -- open file in horizontal split
    open_vsplit_key = "v",        -- open file in vertical split
    toggle_key = "<C-e>",         -- toggle review buffer open/close
  },
}

local ns_id = vim.api.nvim_create_namespace("pr_review_comments")

-- Debug logging helper
local function debug_log(msg)
  if M.config.debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

M._buffer_comments = {}
M._buffer_changes = {}
M._buffer_hunks = {}
M._viewed_files = {}
M._viewed_commit_files = {}  -- commit id -> { path -> true }: viewed per commit (commit mode)
M._commits = nil             -- PR commits, oldest first (see jj.pr_commits)
M._commit_mode = false       -- reviewing a single commit instead of the whole PR
M._current_commit = nil      -- commit id reviewed in commit mode
M._expanded_commits = {}     -- commit id -> bool, expansion state in the commit sidebar
M._collapsed_dirs = {}         -- tracks which directories are collapsed in review buffer
M._drafts = {}                 -- Draft comments being edited (auto-saved)
M._float_win_general = nil     -- General info float (file x/total)
M._float_win_buffer = nil      -- Buffer info float (hunks, stats, comments)
M._float_win_keymaps = nil     -- Keymaps float
M._buffer_jumped = {}          -- Track if we've already jumped to first change in buffer
M._buffer_keymaps_saved = {}   -- Track if we've saved keymaps for this buffer
M._opening_file = false        -- Prevent concurrent file opening operations
M._update_check_timer = nil    -- Timer for checking remote updates
M._last_known_commit = nil     -- Last known commit SHA of the PR branch

-- Review buffer state
M._review_buffer = nil       -- Review buffer number
M._review_window = nil       -- Review window ID
M._review_files = {}         -- List of files with metadata
M._review_files_ordered = {} -- Ordered list matching ReviewBuffer display order
M._review_filter = "all"     -- Current filter: "all", "viewed", "not_viewed"
M._review_sort = nil         -- Current sort (uses config default)

local function get_session_dir()
  local data_path = vim.fn.stdpath("data")
  return data_path .. "/github-pr-reviewer-sessions"
end

-- Root directory of the files under review (the review workspace in workspace mode)
local function review_root()
  return vim.g.pr_review_root or vim.fn.getcwd()
end

-- Absolute path of a PR file (paths in the PR are relative to the review root)
local function review_path(path)
  return review_root() .. "/" .. path
end

-- Store where the review lives and point jj at it
-- state: { mode, root, main_root, workspace?, merge_base, review_change }
local function set_review_location(state)
  vim.g.pr_review_mode = state.mode
  vim.g.pr_review_root = state.root
  vim.g.pr_review_main_root = state.main_root
  vim.g.pr_review_workspace = state.workspace
  vim.g.pr_review_merge_base = state.merge_base
  vim.g.pr_review_head = state.head
  vim.g.pr_review_change = state.review_change
  jj.cwd = state.root
end

local function change_dir(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  -- :cd keeps a tab-local directory, which would otherwise still apply in this tab
  if vim.fn.haslocaldir(-1) == 1 then
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  end
end

local function is_under(path, root)
  return root ~= nil and (path == root or path:sub(1, #root + 1) == root .. "/")
end

-- :cd into the review workspace; the directory Neovim came from is restored when leaving it
local function enter_review_workspace(root)
  if vim.fn.getcwd() == root then
    return
  end
  if not vim.g.pr_review_previous_cwd then
    vim.g.pr_review_previous_cwd = vim.fn.getcwd()
  end
  change_dir(root)
end

-- :cd back out of the review workspace (to where Neovim came from, else to fallback)
local function leave_review_workspace(root, fallback)
  local target = vim.g.pr_review_previous_cwd
  vim.g.pr_review_previous_cwd = nil
  if not target or is_under(target, root) or vim.fn.isdirectory(target) == 0 then
    target = fallback
  end
  if target and (is_under(vim.fn.getcwd(), root) or is_under(vim.fn.getcwd(-1, -1), root)) then
    change_dir(target)
  end
end

-- Delete the buffers of files in root (unmodified ones only unless force). Windows showing them
-- get an empty buffer first, so the window layout survives.
local function wipe_buffers_under(root, force)
  local empty = nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if root and name:sub(1, #root + 1) == root .. "/" and (force or not vim.bo[buf].modified) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        empty = empty and vim.api.nvim_buf_is_valid(empty) and empty or vim.api.nvim_create_buf(true, false)
        pcall(vim.api.nvim_win_set_buf, win, empty)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = force })
    end
  end
end

-- The commit reviewed in commit mode (nil in PR mode) and its index in M._commits
local function current_commit()
  if not M._commit_mode or not M._commits then
    return nil
  end
  for i, commit in ipairs(M._commits) do
    if commit.id == M._current_commit then
      return commit, i
    end
  end
  return nil
end

-- Revision whose content the diff is computed against
local function diff_base_rev()
  local commit = current_commit()
  if commit then
    return commit.parent
  end
  return vim.g.pr_review_merge_base
end

-- Zero-context diff of a review file in the current mode. callback(lines)
local function diff_for_file(path, callback)
  local commit = current_commit()
  if commit then
    jj.diff_commit_file(commit.id, path, callback)
  else
    jj.diff_file(vim.g.pr_review_merge_base, path, callback)
  end
end

local function commit_touches(commit, path)
  for _, f in ipairs(commit.files) do
    if f.path == path then
      return true
    end
  end
  return false
end

-- A file is viewed in the PR once it is viewed in every commit that changes it
local function sync_pr_viewed(path)
  if not M._commits then
    return
  end
  local touched, all_viewed = false, true
  for _, commit in ipairs(M._commits) do
    if commit_touches(commit, path) then
      touched = true
      if not (M._viewed_commit_files[commit.id] or {})[path] then
        all_viewed = false
      end
    end
  end
  if touched then
    M._viewed_files[path] = all_viewed
  end
end

-- Viewed state of a file in the current mode (or in the given commit)
local function is_file_viewed(path, commit_id)
  commit_id = commit_id or (current_commit() or {}).id
  if commit_id then
    return (M._viewed_commit_files[commit_id] or {})[path] or false
  end
  return M._viewed_files[path] or false
end

-- GitHub's "Viewed" checkbox is per file for the whole PR, so it follows M._viewed_files
local viewed_sync_seq = 0
local viewed_pushed_at = {} -- "<pr>:<path>" -> viewed_sync_seq of the last change pushed to GitHub

local function push_viewed(path, viewed)
  local pr_number = vim.g.pr_review_number
  if not M.config.sync_viewed_with_github or not pr_number then
    return
  end
  viewed_sync_seq = viewed_sync_seq + 1
  viewed_pushed_at[pr_number .. ":" .. path] = viewed_sync_seq
  github.set_file_viewed(pr_number, path, viewed, function(ok, err)
    if not ok then
      vim.notify("Failed to sync the viewed state of " .. path .. " to GitHub: " .. (err or "unknown"),
        vim.log.levels.WARN)
    end
  end)
end

-- Mark a file (un)viewed. In commit mode (or with commit_id) only that commit's changes to the
-- file are affected; in PR mode the file is (un)marked in every commit that changes it.
-- A change of the file's PR-level viewed state is pushed to GitHub, unless opts.from_github
-- (which also means PR mode: every commit, whatever the current commit).
local function set_file_viewed(path, viewed, commit_id, opts)
  opts = opts or {}
  if not opts.from_github then
    commit_id = commit_id or (current_commit() or {}).id
  end
  local was_viewed = M._viewed_files[path] == true
  local commits = {}
  if commit_id then
    commits = { commit_id }
  elseif M._commits then
    for _, commit in ipairs(M._commits) do
      if commit_touches(commit, path) then
        table.insert(commits, commit.id)
      end
    end
  end
  for _, id in ipairs(commits) do
    M._viewed_commit_files[id] = M._viewed_commit_files[id] or {}
    M._viewed_commit_files[id][path] = viewed or nil
  end
  if commit_id then
    sync_pr_viewed(path)
  else
    M._viewed_files[path] = viewed
  end
  local now_viewed = M._viewed_files[path] == true
  if now_viewed ~= was_viewed and not opts.from_github then
    push_viewed(path, now_viewed)
  end
end

-- Viewed files / total files of a commit
local function commit_progress(commit)
  local viewed = 0
  for _, f in ipairs(commit.files) do
    if is_file_viewed(f.path, commit.id) then
      viewed = viewed + 1
    end
  end
  return viewed, #commit.files
end

-- Common path prefix of this repo's session files. Keyed by the shared jj repo, so sessions are
-- found from any workspace of the repo
local function session_prefix()
  local key = jj.repo_id() or vim.fn.getcwd()
  -- Convert path to safe filename: /home/otavio/Projetos/api/.jj/repo -> review_home_otavio_Projetos_api_.jj_repo
  local safe_name = key:gsub("^/", ""):gsub("/", "_")
  return get_session_dir() .. "/review_" .. safe_name
end

-- Session file of a PR (default: the PR under review); one file per PR
local function get_session_file(pr_number)
  return string.format("%s_pr%s.json", session_prefix(), tostring(pr_number or vim.g.pr_review_number))
end

local function read_session(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*all")
  file:close()
  local ok, session_data = pcall(vim.fn.json_decode, content)
  if not ok or type(session_data) ~= "table" then
    return nil
  end
  return session_data
end

-- Saved session of a PR (also checks the single session file used before sessions were per PR)
local function read_pr_session(pr_number)
  local data = read_session(get_session_file(pr_number))
  if data then
    return data
  end
  local legacy = read_session(session_prefix() .. ".json")
  if legacy and legacy.pr_number == pr_number then
    return legacy
  end
  return nil
end

-- Session to restore: the one of the PR checked out in the current directory's workspace (its
-- working copy is a review change), else the most recently saved session of this repo.
-- Returns session_data (or nil), the PR checked out here (or nil) and the session file path.
local function find_session()
  local prefix = session_prefix()
  -- Single session file used before sessions were stored per PR
  local legacy_path = prefix .. ".json"
  local legacy = read_session(legacy_path)

  local workspace_pr = jj.current_review_pr(vim.fn.getcwd())
  if workspace_pr then
    local path = get_session_file(workspace_pr)
    local data = read_session(path)
    if not data and legacy and legacy.pr_number == workspace_pr then
      return legacy, workspace_pr, legacy_path
    end
    return data, workspace_pr, path
  end

  local dir = get_session_dir()
  local base = vim.fn.fnamemodify(prefix, ":t") .. "_pr"
  local best, best_time = legacy and legacy_path or nil, legacy and vim.fn.getftime(legacy_path) or -1
  if vim.fn.isdirectory(dir) == 1 then
    for _, name in ipairs(vim.fn.readdir(dir)) do
      if name:sub(1, #base) == base and name:match("%.json$") then
        local path = dir .. "/" .. name
        local time = vim.fn.getftime(path)
        if time > best_time then
          best, best_time = path, time
        end
      end
    end
  end
  if not best then
    return nil, nil, nil
  end
  return read_session(best), nil, best
end

local function save_session()
  if not vim.g.pr_review_number then
    return
  end

  local session_dir = get_session_dir()
  vim.fn.mkdir(session_dir, "p")

  local session_data = {
    pr_number = vim.g.pr_review_number,
    base_branch = vim.g.pr_review_base_branch,
    merge_base = vim.g.pr_review_merge_base,
    review_change = vim.g.pr_review_change,
    previous_change = vim.g.pr_review_previous_change,
    modified_files = vim.g.pr_review_modified_files,
    viewed_files = M._viewed_files,
    viewed_commit_files = M._viewed_commit_files,
    head = vim.g.pr_review_head,
    commit_mode = M._commit_mode,
    current_commit = M._current_commit,
    drafts = M._drafts,
    cwd = vim.fn.getcwd(),
    repo_id = jj.repo_id(),
    mode = vim.g.pr_review_mode,
    root = vim.g.pr_review_root,
    main_root = vim.g.pr_review_main_root,
    workspace = vim.g.pr_review_workspace,
  }

  local session_file = get_session_file()
  local json_str = vim.fn.json_encode(session_data)
  local file = io.open(session_file, "w")
  if file then
    file:write(json_str)
    file:close()
  end
end

local function delete_session()
  vim.fn.delete(get_session_file())
  -- Also drop the pre-per-PR session file if it belongs to this PR
  local legacy_path = session_prefix() .. ".json"
  local legacy = read_session(legacy_path)
  if legacy and legacy.pr_number == vim.g.pr_review_number then
    vim.fn.delete(legacy_path)
  end
end

-- Forward declarations
local get_inline_diff
local load_commits

-- Pending comments live in the user's pending review on GitHub (visible there as "Pending",
-- submittable from either side)

-- Reload the comments of every buffer that shows some (after a review was submitted)
local function reload_comment_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and M._buffer_comments[buf] then
      M.load_comments_for_buffer(buf, true)
    end
  end
end

-- Add a comment (lines start_line..line, start_line optional) to the pending review on GitHub
-- restore_draft (optional) keeps the text as a draft when adding fails (see take_draft)
local function add_pending_comment_to_github(bufnr, pr_number, path, line, body, start_line, restore_draft)
  vim.notify("Adding pending comment...", vim.log.levels.INFO)
  github.add_pending_comment(pr_number, path, line, body, start_line, function(ok, err)
    if ok then
      vim.notify("✅ Pending comment added to your pending review on GitHub", vim.log.levels.INFO)
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.load_comments_for_buffer(bufnr, true)
      end
    else
      vim.notify("❌ Failed to add pending comment: " .. (err or "unknown"), vim.log.levels.ERROR)
      if restore_draft then
        restore_draft()
      end
    end
  end)
end

-- Pending comments that older versions kept in the session file: move them to the pending review
local function migrate_local_pending_comments(pending_by_pr)
  for pr_number, comments in pairs(pending_by_pr or {}) do
    pr_number = tonumber(pr_number)
    for _, c in ipairs(type(comments) == "table" and comments or {}) do
      local body = (c.body or ""):gsub("\n<!%-%- PR_RANGE:%d+%-%d+ %-%->", "")
      github.add_pending_comment(pr_number, c.path, c.line, body, c.start_line, function(ok, err)
        if ok then
          vim.notify(string.format("Moved pending comment on %s:%d to GitHub", c.path, c.line), vim.log.levels.INFO)
        else
          vim.notify(string.format("❌ Failed to move pending comment on %s:%d to GitHub (%s):\n%s",
            c.path, c.line, err or "unknown", body), vim.log.levels.ERROR)
        end
      end)
    end
  end
end

-- Submit the pending review on GitHub with event; without a pending review, fallback(pr_number,
-- body, callback) sends a plain review. callback(ok, err)
local function submit_review(pr_number, event, body, fallback, callback)
  github.submit_pending_review(pr_number, event, body, function(ok, err, submitted)
    if submitted then
      reload_comment_buffers()
    end
    if not ok or submitted or not fallback then
      callback(ok, err)
      return
    end
    fallback(pr_number, body, callback)
  end)
end

-- Check if a line is part of the diff (can receive comments)
local function is_line_in_diff(bufnr, line)
  local changed_lines = M._buffer_changes[bufnr]
  if not changed_lines then
    return false
  end

  for _, changed_line in ipairs(changed_lines) do
    if changed_line == line then
      return true
    end
  end

  return false
end

-- Check if the PR branch has been updated remotely
local function check_for_remote_updates()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    return
  end

  -- Get current HEAD commit of the PR
  local cmd = string.format("gh pr view %d --json headRefOid --jq '.headRefOid'", pr_number)
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        return
      end

      local remote_commit = data[1]:gsub("%s+", "")

      -- First check - store the commit
      if not M._last_known_commit then
        M._last_known_commit = remote_commit
        return
      end

      -- Compare with last known commit
      if remote_commit ~= M._last_known_commit then
        vim.schedule(function()
          vim.notify("⚠️ PR branch has been updated! Use :PRRefresh to sync changes.", vim.log.levels.WARN)
        end)
        M._last_known_commit = remote_commit
      end
    end,
  })
end

-- Start polling for remote updates
local function start_update_polling()
  if M._update_check_timer then
    return -- Already polling
  end

  -- Check immediately
  check_for_remote_updates()

  -- Then check every 10 seconds
  M._update_check_timer = vim.fn.timer_start(10000, function()
    check_for_remote_updates()
  end, { ["repeat"] = -1 })
end

-- Stop polling for remote updates
local function stop_update_polling()
  if M._update_check_timer then
    vim.fn.timer_stop(M._update_check_timer)
    M._update_check_timer = nil
  end
  M._last_known_commit = nil
end

-- Collect all files from PR with their metadata
local function collect_pr_files(callback)
  local function with_files(changed)
    local files = {}
    for _, f in ipairs(changed) do
      table.insert(files, {
        path = f.path,
        status = f.status, -- M=modified, A=added, D=deleted
        viewed = is_file_viewed(f.path),
        stats = { additions = 0, modifications = 0, deletions = 0 },
      })
    end

    -- Now get stats for each file
    local pending = #files
    if pending == 0 then
      vim.schedule(function()
        callback(files)
      end)
      return
    end

    for _, file in ipairs(files) do
      get_inline_diff(file.path, file.status, function(hunks)
        if hunks and #hunks > 0 then
          local additions = 0
          local deletions = 0
          local modifications = 0

          for _, hunk in ipairs(hunks) do
            local added = #hunk.added_lines
            local removed = #hunk.removed_lines

            if added > 0 and removed > 0 then
              modifications = modifications + math.min(added, removed)
              additions = additions + math.max(0, added - removed)
              deletions = deletions + math.max(0, removed - added)
            elseif added > 0 then
              additions = additions + added
            elseif removed > 0 then
              deletions = deletions + removed
            end
          end

          file.stats = {
            additions = additions,
            modifications = modifications,
            deletions = deletions,
          }
        end

        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            callback(files)
          end)
        end
      end)
    end
  end

  -- In commit mode the files are the ones changed by the current commit
  local commit = current_commit()
  if commit then
    with_files(commit.files)
  else
    jj.changed_files(vim.g.pr_review_merge_base, with_files)
  end
end

local function get_relative_path(bufnr)
  local full_path = vim.api.nvim_buf_get_name(bufnr)

  -- Remove [DELETED] suffix if present
  full_path = full_path:gsub(" %[DELETED%]$", "")

  local cwd = review_root()
  if full_path:sub(1, #cwd) == cwd then
    return full_path:sub(#cwd + 2)
  end
  return full_path
end

local function get_changed_lines_for_file(file_path, status, callback)
  diff_for_file(file_path, function(data)
    local all_lines = {}
    if data then
      for _, line in ipairs(data) do
        local start_line, count = line:match("^@@%s+%-%d+[,%d]*%s+%+(%d+),?(%d*)%s+@@")
        if start_line then
          start_line = tonumber(start_line)
          count = tonumber(count) or 1
          if count == 0 then count = 1 end
          for i = 0, count - 1 do
            table.insert(all_lines, start_line + i)
          end
        end
      end
    end

    table.sort(all_lines)

    local unique_lines = {}
    local seen = {}
    for _, l in ipairs(all_lines) do
      if not seen[l] then
        seen[l] = true
        table.insert(unique_lines, l)
      end
    end

    local hunks = {}
    if #unique_lines > 0 then
      local current_hunk = { start_line = unique_lines[1], end_line = unique_lines[1] }
      for i = 2, #unique_lines do
        if unique_lines[i] == current_hunk.end_line + 1 then
          current_hunk.end_line = unique_lines[i]
        else
          table.insert(hunks, current_hunk)
          current_hunk = { start_line = unique_lines[i], end_line = unique_lines[i] }
        end
      end
      table.insert(hunks, current_hunk)
    end

    vim.schedule(function()
      callback(unique_lines, hunks)
    end)
  end)
end

-- Forward declaration
local update_changes_float

get_inline_diff = function(file_path, status, callback)
  diff_for_file(file_path, function(data)
    if not data then
      vim.schedule(function()
        callback({})
      end)
      return
    end

    local hunks = {}
    local current_hunk = nil
    local in_hunk = false

    for _, line in ipairs(data) do
      -- Parse hunk header: @@ -old_start,old_count +new_start,new_count @@
      local old_start, old_count, new_start, new_count = line:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")
      if old_start then
        old_start = tonumber(old_start)
        old_count = tonumber(old_count) or 1
        new_start = tonumber(new_start)
        new_count = tonumber(new_count) or 1

        current_hunk = {
          old_start = old_start,
          old_count = old_count,
          new_start = new_start,
          new_count = new_count,
          removed_lines = {},
          added_lines = {},
        }
        table.insert(hunks, current_hunk)
        in_hunk = true
      elseif in_hunk and current_hunk then
        if line:match("^%-") and not line:match("^%-%-%- ") then
          -- Removed line
          table.insert(current_hunk.removed_lines, line:sub(2))
        elseif line:match("^%+") and not line:match("^%+%+%+ ") then
          -- Added line (current content)
          table.insert(current_hunk.added_lines, line:sub(2))
        end
      end
    end

    vim.schedule(function()
      callback(hunks)
    end)
  end)
end

local function close_float_wins()
  if M._float_win_general and vim.api.nvim_win_is_valid(M._float_win_general) then
    vim.api.nvim_win_close(M._float_win_general, true)
  end
  if M._float_win_buffer and vim.api.nvim_win_is_valid(M._float_win_buffer) then
    vim.api.nvim_win_close(M._float_win_buffer, true)
  end
  if M._float_win_keymaps and vim.api.nvim_win_is_valid(M._float_win_keymaps) then
    vim.api.nvim_win_close(M._float_win_keymaps, true)
  end
  M._float_win_general = nil
  M._float_win_buffer = nil
  M._float_win_keymaps = nil
end

-- Toggle floating windows visibility
function M.toggle_floats()
  if not vim.g.pr_review_number then
    return
  end

  M.config.show_floats = not M.config.show_floats

  if M.config.show_floats then
    -- Show floats
    update_changes_float()
    vim.notify("Floating windows enabled", vim.log.levels.INFO)
  else
    -- Hide floats
    close_float_wins()
    vim.notify("Floating windows disabled", vim.log.levels.INFO)
  end
end

-- Group files by directory
local function group_files_by_directory(files)
  local grouped = {}
  for _, file in ipairs(files) do
    local dir = file.path:match("(.+)/[^/]+$") or "."
    if not grouped[dir] then
      grouped[dir] = {}
    end
    table.insert(grouped[dir], file)
  end
  return grouped
end

-- Sidebar selection: the entry under the cursor gets a background (all lines of a wrapped entry)
local selection_ns = vim.api.nvim_create_namespace("pr_review_selection")

local function sidebar_item_key(item)
  if type(item) ~= "table" then
    return nil
  elseif item.is_commit then
    return "commit:" .. item.commit.id
  elseif item.is_commit_file then
    return "commit_file:" .. item.commit.id .. ":" .. item.path
  elseif item.is_directory then
    return "dir:" .. item.path
  end
  return "file:" .. tostring(item.path)
end

local function update_sidebar_selection()
  local buf, win = M._review_buffer, M._review_window
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end

  local line = vim.api.nvim_win_get_cursor(win)[1]
  local map = vim.b[buf].pr_file_map
  local key = type(map) == "table" and sidebar_item_key(map[line]) or nil
  local first, last = line, line
  if key then
    while first > 1 and sidebar_item_key(map[first - 1]) == key do
      first = first - 1
    end
    local count = vim.api.nvim_buf_line_count(buf)
    while last < count and sidebar_item_key(map[last + 1]) == key do
      last = last + 1
    end
  end
  for l = first, last do
    vim.api.nvim_buf_set_extmark(buf, selection_ns, l - 1, 0, { line_hl_group = "PRReviewSelection", priority = 10 })
  end
end

-- Apply lines, highlights and the line -> item map to the review buffer
local function set_review_buffer_content(lines, highlights, file_map)
  vim.bo[M._review_buffer].modifiable = true
  vim.api.nvim_buf_set_lines(M._review_buffer, 0, -1, false, lines)
  vim.bo[M._review_buffer].modifiable = false

  local ns = vim.api.nvim_create_namespace("pr_review_buffer")
  vim.api.nvim_buf_clear_namespace(M._review_buffer, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, hl.start_col or 0, hl.end_col or -1)
  end

  vim.b[M._review_buffer].pr_file_map = file_map
  update_sidebar_selection()
end

-- Word-wrap text to lines of at most width display cells (long words are split)
local function wrap_words(text, width)
  local result, line = {}, ""
  for w in text:gmatch("%S+") do
    local word = w
    while vim.fn.strdisplaywidth(word) > width do
      if line ~= "" then
        table.insert(result, line)
        line = ""
      end
      local n = vim.fn.strcharlen(word)
      local cut = n
      while cut > 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(word, 0, cut)) > width do
        cut = cut - 1
      end
      table.insert(result, vim.fn.strcharpart(word, 0, cut))
      word = vim.fn.strcharpart(word, cut)
    end
    if line == "" then
      line = word
    elseif vim.fn.strdisplaywidth(line) + 1 + vim.fn.strdisplaywidth(word) <= width then
      line = line .. " " .. word
    else
      table.insert(result, line)
      line = word
    end
  end
  if line ~= "" or #result == 0 then
    table.insert(result, line)
  end
  return result
end

-- Render the commit sidebar: a tree of the PR's commits and the files each one changes
local function render_commit_sidebar()
  local icons = M.config.show_icons
  local current_file_path = get_relative_path(vim.api.nvim_get_current_buf())
  local current = current_commit()
  local lines, highlights, file_map = {}, {}, {}
  local function add(line, hl_group)
    table.insert(lines, line)
    if hl_group then
      table.insert(highlights, { line = #lines - 1, hl_group = hl_group })
    end
    return #lines
  end

  -- Usable width of the sidebar window (it doesn't wrap lines)
  local width = M.config.review_buffer.width
  if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
    width = vim.api.nvim_win_get_width(M._review_window)
  end
  width = width - 1

  local commits = M._commits or {}
  local viewed_commits = 0
  for _, commit in ipairs(commits) do
    local viewed, total = commit_progress(commit)
    if viewed == total then
      viewed_commits = viewed_commits + 1
    end
  end

  local cfg = M.config.review_buffer
  add("═══ PR Commits ═══")
  add("")
  add(string.format("[%s] Whole PR | [%s] Toggle | [q] Close", M.config.commit_mode_toggle_key, cfg.toggle_key))
  add("Open: [<CR>] Commit/File  [m] Mark viewed")
  add(string.format("%d/%d commits viewed", viewed_commits, #commits))
  add("")
  if not M._commits then
    add("Loading commits...", "Comment")
  end

  -- Files of the current commit are the navigation order for next/prev file
  M._review_files_ordered = {}

  for _, commit in ipairs(commits) do
    local viewed, total = commit_progress(commit)
    local is_current = current and current.id == commit.id
    local expanded = M._expanded_commits[commit.id]
    if expanded == nil then
      expanded = is_current
    end
    local arrow = expanded and (icons and "▾" or "-") or (icons and "▸" or "+")
    local check = viewed == total and (icons and "✓" or "[V]") or (icons and "○" or "[ ]")
    local hl = is_current and "PRReviewCurrent" or (viewed == total and "Comment" or nil)
    local item = { is_commit = true, commit = commit }

    -- Metadata first so it never clips; the subject wraps under itself (hanging indent)
    local lead = arrow .. " " .. check .. " "
    local prefix = string.format("%s%s (%d/%d)%s%s ", lead, commit.change, viewed, total,
      commit.is_merge and " [merge]" or "", is_current and (icons and " ➤" or " >") or "")
    local indent = vim.fn.strdisplaywidth(prefix)
    local first_prefix = prefix
    local first_line = #lines + 1
    if width - indent < 20 then
      -- Too narrow to wrap next to the metadata: put the subject on its own lines
      add(vim.trim(prefix), hl)
      file_map[#lines] = item
      indent, first_prefix = 4, string.rep(" ", 4)
    end
    for i, part in ipairs(wrap_words(commit.subject, math.max(width - indent, 10))) do
      add((i == 1 and first_prefix or string.rep(" ", indent)) .. part, hl)
      file_map[#lines] = item
    end
    -- jj change id: unique prefix highlighted, the rest dimmed (like `jj log`)
    table.insert(highlights, { line = first_line - 1, hl_group = "PRReviewChangeIdPrefix",
      start_col = #lead, end_col = #lead + #commit.change_prefix })
    table.insert(highlights, { line = first_line - 1, hl_group = "PRReviewChangeIdRest",
      start_col = #lead + #commit.change_prefix, end_col = #lead + #commit.change })

    if expanded then
      for _, f in ipairs(commit.files) do
        local file_viewed = is_file_viewed(f.path, commit.id)
        local is_current_file = is_current and f.path == current_file_path
        local f_check = file_viewed and (icons and "✓" or "[V]") or (icons and "○" or "[ ]")
        local hl = is_current_file and "Search" or (file_viewed and "Comment" or
          (f.status == "A" and "DiffAdd" or (f.status == "D" and "DiffDelete" or "DiffChange")))
        local f_idx = add(string.format("  %s %s %s %s", is_current_file and (icons and "➤" or ">") or " ", f_check,
          f.status, f.path), hl)
        file_map[f_idx] = { is_commit_file = true, commit = commit, path = f.path, status = f.status }
      end
    end
  end

  for _, file in ipairs(M._review_files) do
    table.insert(M._review_files_ordered, file)
  end

  set_review_buffer_content(lines, highlights, file_map)
end

-- Render the review buffer
local function render_review_buffer()
  if not M._review_buffer or not vim.api.nvim_buf_is_valid(M._review_buffer) then
    return
  end

  -- The sidebar follows the review mode: commit tree in commit mode, file list for the whole PR
  if M._commit_mode then
    render_commit_sidebar()
    return
  end

  -- Get current file to highlight it
  local current_file_path = nil
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
    current_file_path = get_relative_path(current_buf)
  end

  local lines = {}
  local highlights = {}
  local file_map = {}          -- Maps line number to file
  M._review_files_ordered = {} -- Reset ordered list

  -- Header
  local cfg = M.config.review_buffer
  table.insert(lines, "═══ PR Review ═══")
  table.insert(lines, "")
  table.insert(lines, string.format("[%s] Commits | [%s] Toggle | [q] Close", M.config.commit_mode_toggle_key,
    cfg.toggle_key))
  table.insert(lines,
    string.format("Filters: [%s] All  [%s] Viewed  [%s] Not Viewed", cfg.filter_all_key, cfg.filter_viewed_key,
      cfg.filter_not_viewed_key))
  table.insert(lines,
    string.format("Open: [<CR>] Current  [%s] Split  [%s] VSplit", cfg.open_split_key, cfg.open_vsplit_key))
  table.insert(lines, string.format("Sort: %s | Filter: %s", M._review_sort or cfg.sort_by, M._review_filter))
  table.insert(lines, "")

  -- Filter files based on current filter
  local filtered_files = {}
  for _, file in ipairs(M._review_files) do
    if M._review_filter == "all" then
      table.insert(filtered_files, file)
    elseif M._review_filter == "viewed" and file.viewed then
      table.insert(filtered_files, file)
    elseif M._review_filter == "not_viewed" and not file.viewed then
      table.insert(filtered_files, file)
    end
  end

  -- Group and sort
  if cfg.group_by_directory then
    local grouped = group_files_by_directory(filtered_files)
    local dirs = vim.tbl_keys(grouped)
    table.sort(dirs)

    for _, dir in ipairs(dirs) do
      local is_collapsed = M._collapsed_dirs[dir]
      local icon = is_collapsed and (M.config.show_icons and "▶" or "+") or (M.config.show_icons and "▼" or "-")
      local dir_line = string.format("%s 📁 %s/", icon, dir)
      local dir_line_idx = #lines + 1
      table.insert(lines, dir_line)
      table.insert(highlights, { line = #lines - 1, hl_group = "Directory" })

      -- Store directory reference in file_map so we can toggle it
      file_map[dir_line_idx] = { is_directory = true, path = dir }

      -- Only show files if directory is not collapsed
      if not is_collapsed then
        for _, file in ipairs(grouped[dir]) do
          -- Add to ordered list
          table.insert(M._review_files_ordered, file)

          local filename = file.path:match("[^/]+$")
          local status_icon = file.status == "M" and "M" or
              (file.status == "A" and "A" or (file.status == "D" and "D" or "N"))
          local viewed_icon = file.viewed and (M.config.show_icons and "✓" or "[V]") or
              (M.config.show_icons and "○" or "[ ]")
          local stats_str = string.format("+%d ~%d -%d", file.stats.additions, file.stats.modifications,
            file.stats.deletions)

          -- Add indicator for current file
          local current_indicator = ""
          if current_file_path and file.path == current_file_path then
            current_indicator = M.config.show_icons and " ➤" or " >"
          end

          local line = string.format("  %s %s %s  %s%s", viewed_icon, status_icon, filename, stats_str, current_indicator)
          local line_idx = #lines + 1
          table.insert(lines, line)
          file_map[line_idx] = file

          -- Calculate filename position in the line for highlighting
          local filename_start = string.len("  " .. viewed_icon .. " " .. status_icon .. " ")
          local filename_end = filename_start + string.len(filename)

          -- Highlight based on status or if current file
          if current_file_path and file.path == current_file_path then
            -- Highlight entire line for current file
            table.insert(highlights, { line = line_idx - 1, hl_group = "PRReviewCurrent" })
            -- Highlight filename with special color
            table.insert(highlights,
              { line = line_idx - 1, hl_group = "Search", start_col = filename_start, end_col = filename_end })
          else
            -- Apply viewed dimming
            if file.viewed then
              table.insert(highlights, { line = line_idx - 1, hl_group = "Comment" })
            elseif file.status == "A" or file.status == "N" then
              table.insert(highlights, { line = line_idx - 1, hl_group = "DiffAdd" })
            elseif file.status == "D" then
              table.insert(highlights, { line = line_idx - 1, hl_group = "DiffDelete" })
            elseif file.status == "M" then
              table.insert(highlights, { line = line_idx - 1, hl_group = "DiffChange" })
            end
          end
        end
      end -- end of if not is_collapsed
      table.insert(lines, "")
    end
  else
    -- Flat list
    for _, file in ipairs(filtered_files) do
      -- Add to ordered list
      table.insert(M._review_files_ordered, file)

      local status_icon = file.status == "M" and "M" or
          (file.status == "A" and "A" or (file.status == "D" and "D" or "N"))
      local viewed_icon = file.viewed and (M.config.show_icons and "✓" or "[V]") or
          (M.config.show_icons and "○" or "[ ]")
      local stats_str = string.format("+%d ~%d -%d", file.stats.additions, file.stats.modifications, file.stats
        .deletions)

      -- Add indicator for current file
      local current_indicator = ""
      if current_file_path and file.path == current_file_path then
        current_indicator = M.config.show_icons and " ➤" or " >"
      end

      local line = string.format("%s %s %s  %s%s", viewed_icon, status_icon, file.path, stats_str, current_indicator)
      local line_idx = #lines + 1
      table.insert(lines, line)
      file_map[line_idx] = file

      -- Calculate file path position in the line for highlighting
      local filepath_start = string.len(viewed_icon .. " " .. status_icon .. " ")
      local filepath_end = filepath_start + string.len(file.path)

      -- Highlight based on status or if current file
      if current_file_path and file.path == current_file_path then
        -- Highlight entire line for current file
        table.insert(highlights, { line = line_idx - 1, hl_group = "PRReviewCurrent" })
        -- Highlight filepath with special color
        table.insert(highlights,
          { line = line_idx - 1, hl_group = "Search", start_col = filepath_start, end_col = filepath_end })
      else
        -- Apply viewed dimming
        if file.viewed then
          table.insert(highlights, { line = line_idx - 1, hl_group = "Comment" })
        elseif file.status == "A" or file.status == "N" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffAdd" })
        elseif file.status == "D" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffDelete" })
        elseif file.status == "M" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffChange" })
        end
      end
    end
  end

  -- Set lines
  vim.bo[M._review_buffer].modifiable = true
  vim.api.nvim_buf_set_lines(M._review_buffer, 0, -1, false, lines)
  vim.bo[M._review_buffer].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("pr_review_buffer")
  vim.api.nvim_buf_clear_namespace(M._review_buffer, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.start_col and hl.end_col then
      -- Highlight specific range (for file name)
      vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, hl.start_col, hl.end_col)
    else
      -- Highlight entire line
      vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, 0, -1)
    end
  end

  -- Store file map in buffer variable
  vim.b[M._review_buffer].pr_file_map = file_map
  update_sidebar_selection()
end

-- Helper to open a file (including deleted files)
local function open_file_safe(file, split_cmd)
  -- Check if we're in the review buffer - if so, move to another window first
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf == M._review_buffer then
    -- Find a non-review window to use
    local found_window = false
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if buf ~= M._review_buffer and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        found_window = true
        break
      end
    end

    -- If we didn't find another window, create a new split to the right
    if not found_window then
      -- Make sure we're in the review buffer window
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == M._review_buffer then
          vim.api.nvim_set_current_win(win)
          break
        end
      end
      -- Create a new window to the right with an empty buffer
      vim.cmd("rightbelow vnew")
    elseif split_cmd then
      -- Create split in the found window
      if split_cmd == "split" then
        vim.cmd("split")
      elseif split_cmd == "vsplit" then
        vim.cmd("vsplit")
      end
    end
  elseif split_cmd then
    -- Not in review buffer, just create the split
    if split_cmd == "split" then
      vim.cmd("split")
    elseif split_cmd == "vsplit" then
      vim.cmd("vsplit")
    end
  end

  if file.status == "D" then
    -- Check if buffer already exists
    local deleted_buf_name = file.path .. " [DELETED]"
    local existing_buf = vim.fn.bufnr(deleted_buf_name)

    if existing_buf ~= -1 then
      -- Buffer already exists, just switch to it
      vim.api.nvim_set_current_buf(existing_buf)
      -- Don't auto-mark as viewed - user should explicitly mark with mark_as_viewed_key
    else
      -- Open deleted file from merge_base (the PR's base commit, matching GitHub's view)
      jj.file_lines_at_async(diff_base_rev() or "@-", file.path, function(data)
        if not data or #data == 0 then
          vim.notify("Could not load deleted file content", vim.log.levels.ERROR)
          return
        end

        -- Create scratch buffer with old content
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, data)
        vim.bo[buf].filetype = vim.filetype.match({ filename = file.path }) or ""
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_set_name(buf, deleted_buf_name)

        -- Highlight all lines in red (deleted)
        local deleted_ns = vim.api.nvim_create_namespace("pr_review_deleted_file")
        local line_count = vim.api.nvim_buf_line_count(buf)
        for i = 0, line_count - 1 do
          vim.api.nvim_buf_set_extmark(buf, deleted_ns, i, 0, {
            line_hl_group = "DiffDelete",
            sign_text = "-",
            sign_hl_group = "DiffDelete",
          })
        end

        vim.api.nvim_set_current_buf(buf)
        -- Don't auto-mark as viewed - user should explicitly mark with mark_as_viewed_key
      end)
    end
  else
    -- Open normal file
    vim.cmd("edit " .. vim.fn.fnameescape(review_path(file.path)))
  end
end

-- Open file from review buffer (handles deleted files and directory toggling)
local function open_file_from_review(split_type)
  -- Prevent concurrent file opening operations
  if M._opening_file then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file_map = vim.b[bufnr].pr_file_map
  if not file_map or type(file_map) ~= "table" then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local item = file_map[line]

  if not item or type(item) ~= "table" then
    return
  end

  -- Check if it's a directory - toggle collapse/expand
  if item.is_directory then
    local dir = item.path
    M._collapsed_dirs[dir] = not M._collapsed_dirs[dir]
    render_review_buffer()
    return
  end

  -- Commit sidebar: a commit row enters that commit (or folds it if it is the current one)
  local current = current_commit()
  if item.is_commit then
    if current and current.id == item.commit.id then
      local expanded = M._expanded_commits[item.commit.id]
      M._expanded_commits[item.commit.id] = expanded == false
      render_review_buffer()
    else
      M._expanded_commits[item.commit.id] = true
      M.goto_commit(item.commit.id)
    end
    return
  end

  -- Commit sidebar: a file row enters its commit first if needed
  if item.is_commit_file then
    if not current or current.id ~= item.commit.id then
      M.goto_commit(item.commit.id, item.path)
      return
    end
    local found = nil
    for _, f in ipairs(M._review_files) do
      if f.path == item.path then
        found = f
      end
    end
    item = found or { path = item.path, status = item.status }
  end

  -- It's a file
  local file = item
  if not file.path then
    return
  end

  M._opening_file = true
  open_file_safe(file, split_type)
  M._opening_file = false
end

-- ===== Sidebar folds (Vim fold keys): directories in the file sidebar, commits in the commit sidebar =====

local function sidebar_rows(bufnr)
  local rows = {}
  for line, item in pairs(vim.b[bufnr].pr_file_map or {}) do
    if type(item) == "table" then
      rows[tonumber(line)] = item
    end
  end
  return rows
end

local function is_fold_item(item)
  return item.is_directory or item.is_commit
end

local function fold_key(item)
  return item.is_directory and ("dir:" .. item.path) or ("commit:" .. item.commit.id)
end

local function is_folded(item)
  if item.is_directory then
    return M._collapsed_dirs[item.path] == true
  end
  local expanded = M._expanded_commits[item.commit.id]
  if expanded == nil then
    local current = current_commit()
    expanded = current ~= nil and current.id == item.commit.id
  end
  return not expanded
end

local function set_folded(item, folded)
  if item.is_directory then
    M._collapsed_dirs[item.path] = folded or nil
  else
    M._expanded_commits[item.commit.id] = not folded
  end
end

-- The fold row of the cursor line: the row itself, or the directory / commit it belongs to
local function fold_row_at_cursor(bufnr)
  local rows = sidebar_rows(bufnr)
  for line = vim.api.nvim_win_get_cursor(0)[1], 1, -1 do
    local item = rows[line]
    if item and is_fold_item(item) then
      return item
    end
  end
end

-- Re-render and put the cursor on the row with fold key `key` (when it is still there)
local function render_keeping_row(bufnr, key)
  render_review_buffer()
  if not key then
    return
  end
  for line, item in pairs(sidebar_rows(bufnr)) do
    if is_fold_item(item) and fold_key(item) == key then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
end

-- action: "open" | "close" | "toggle" the fold under the cursor
local function sidebar_fold(bufnr, action)
  local item = fold_row_at_cursor(bufnr)
  if not item then
    return
  end
  local folded = action == "close" or (action == "toggle" and not is_folded(item))
  set_folded(item, folded)
  render_keeping_row(bufnr, fold_key(item))
end

-- Open (folded = false) or close every fold of the sidebar
local function sidebar_fold_all(bufnr, folded)
  local cursor_item = fold_row_at_cursor(bufnr)
  for _, item in pairs(sidebar_rows(bufnr)) do
    if is_fold_item(item) then
      set_folded(item, folded)
    end
  end
  render_keeping_row(bufnr, cursor_item and fold_key(cursor_item))
end

-- Toggle filter
local function set_review_filter(filter)
  M._review_filter = filter
  render_review_buffer()
end

-- Setup keymaps for review buffer
local function setup_review_buffer_keymaps(bufnr)
  local cfg = M.config.review_buffer

  -- Selection background follows the cursor
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("PRReviewSidebarSelection", { clear = true }),
    buffer = bufnr,
    callback = update_sidebar_selection,
  })

  -- Store the callback in a global table so it can be called
  _G._pr_reviewer_open_file = function()
    open_file_from_review(nil)
  end

  -- Open file - using nvim_buf_set_keymap for compatibility
  vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", [[<Cmd>lua _G._pr_reviewer_open_file()<CR>]],
    { noremap = true, silent = true, nowait = true })

  -- Mouse: single click folds (directory, current commit), double click opens a file or enters a
  -- commit. A double click also delivers the first click, so each handler only acts on its own rows.
  local function mouse_item()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= vim.api.nvim_get_current_win() or pos.line < 1
        or pos.line > vim.api.nvim_buf_line_count(bufnr) then
      return nil
    end
    vim.api.nvim_win_set_cursor(pos.winid, { pos.line, 0 })
    local item = (vim.b[bufnr].pr_file_map or {})[pos.line]
    return type(item) == "table" and item or nil
  end
  local function is_fold_row(item)
    if item.is_directory then
      return true
    end
    local current = current_commit()
    return item.is_commit and current ~= nil and current.id == item.commit.id
  end

  vim.keymap.set("n", "<LeftRelease>", function()
    local item = mouse_item()
    if item and is_fold_row(item) then
      open_file_from_review(nil)
    end
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Fold item under the mouse" })

  vim.keymap.set("n", "<2-LeftMouse>", function()
    local item = mouse_item()
    if item and not is_fold_row(item) then
      open_file_from_review(nil)
    end
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open item under the mouse" })

  -- Vim fold keys on directories / commits (on a file row: its directory / commit)
  local fold_maps = {
    { "zo", function() sidebar_fold(bufnr, "open") end, "Open fold" },
    { "zc", function() sidebar_fold(bufnr, "close") end, "Close fold" },
    { "za", function() sidebar_fold(bufnr, "toggle") end, "Toggle fold" },
    { "zR", function() sidebar_fold_all(bufnr, false) end, "Open all folds" },
    { "zM", function() sidebar_fold_all(bufnr, true) end, "Close all folds" },
  }
  for _, map in ipairs(fold_maps) do
    vim.keymap.set("n", map[1], map[2], { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = map[3] })
  end

  vim.keymap.set("n", cfg.open_split_key, function()
    open_file_from_review("split")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open file in split" })
  vim.keymap.set("n", cfg.open_vsplit_key, function()
    open_file_from_review("vsplit")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open file in vsplit" })

  -- Filters
  vim.keymap.set("n", cfg.filter_all_key, function() set_review_filter("all") end,
    { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: all files" })
  vim.keymap.set("n", cfg.filter_viewed_key, function() set_review_filter("viewed") end,
    { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: viewed files" })
  vim.keymap.set("n", cfg.filter_not_viewed_key, function() set_review_filter("not_viewed") end,
    { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: not viewed files" })

  -- Note: We DON'T register mark_as_viewed_key here because:
  -- 1. In ReviewBuffer, <CR> should open files, not mark them as viewed
  -- 2. mark_as_viewed is for file buffers, not the ReviewBuffer itself
  -- 3. If user wants to mark as viewed from ReviewBuffer, they can use a different key (e.g., 'm')

  -- Optional: Add a different key for marking files as viewed from ReviewBuffer
  vim.keymap.set("n", "m", function()
    local buf = vim.api.nvim_get_current_buf()
    local file_map = vim.b[buf].pr_file_map
    if not file_map or type(file_map) ~= "table" then return end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local file = file_map[line]
    if not file or type(file) ~= "table" then return end

    if file.is_commit then
      -- Toggle all files of the commit
      local viewed, total = commit_progress(file.commit)
      for _, f in ipairs(file.commit.files) do
        set_file_viewed(f.path, viewed < total, file.commit.id)
      end
    elseif file.is_commit_file then
      set_file_viewed(file.path, not is_file_viewed(file.path, file.commit.id), file.commit.id)
    elseif file.path and not file.is_directory then
      file.viewed = true
      set_file_viewed(file.path, true)
    else
      return
    end
    save_session()
    M.refresh_review_buffer()
    update_changes_float()
    -- Move to next line
    vim.cmd("normal! j")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Mark file as viewed" })

  -- Close buffer
  vim.keymap.set("n", "q", function()
    if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
      vim.api.nvim_win_close(M._review_window, true)
    end
    M._review_window = nil
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Close review buffer" })
end

-- Open or refresh review buffer
function M.open_review_buffer(callback, files_loaded)
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Collect files if not already collected (files_loaded: collected, possibly empty)
  if #M._review_files == 0 and not files_loaded then
    collect_pr_files(function(files)
      M._review_files = files
      M.open_review_buffer(callback, true) -- Recursive call after files are loaded
    end)
    return
  end

  -- Create buffer if it doesn't exist
  if not M._review_buffer or not vim.api.nvim_buf_is_valid(M._review_buffer) then
    M._review_buffer = vim.api.nvim_create_buf(false, true)

    -- Try to set name, if it fails (buffer already exists), wipe the old one
    local success, err = pcall(vim.api.nvim_buf_set_name, M._review_buffer, "PR Review")
    if not success then
      -- Find and delete the existing buffer with this name
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match("PR Review$") then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      -- Try again
      vim.api.nvim_buf_set_name(M._review_buffer, "PR Review")
    end

    vim.bo[M._review_buffer].buftype = "nofile"
    vim.bo[M._review_buffer].bufhidden = "hide"
    vim.bo[M._review_buffer].swapfile = false
    -- Don't set filetype yet - it might trigger ftplugins that override keymaps
    -- vim.bo[M._review_buffer].filetype = "pr-review"

    setup_review_buffer_keymaps(M._review_buffer)
    debug_log("Review buffer keymaps set up for buffer " .. M._review_buffer)
  end

  -- Render content
  render_review_buffer()

  -- Re-apply keymaps after rendering (in case buffer was recreated)
  setup_review_buffer_keymaps(M._review_buffer)

  -- Set modifiable to false after everything is set up
  vim.bo[M._review_buffer].modifiable = false

  -- Open window if not already open
  if not M._review_window or not vim.api.nvim_win_is_valid(M._review_window) then
    local cfg = M.config.review_buffer
    local win_cmd

    if cfg.position == "left" then
      win_cmd = string.format("topleft vertical %d split", cfg.width)
    elseif cfg.position == "right" then
      win_cmd = string.format("botright vertical %d split", cfg.width)
    elseif cfg.position == "top" then
      win_cmd = string.format("topleft %d split", cfg.height)
    else -- bottom
      win_cmd = string.format("botright %d split", cfg.height)
    end

    vim.cmd(win_cmd)
    M._review_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M._review_window, M._review_buffer)
    vim.api.nvim_win_set_option(M._review_window, "number", false)
    vim.api.nvim_win_set_option(M._review_window, "relativenumber", false)
    vim.api.nvim_win_set_option(M._review_window, "signcolumn", "no")
    vim.api.nvim_win_set_option(M._review_window, "wrap", false)

    -- Fix window size (width for left/right, height for top/bottom)
    if cfg.position == "left" or cfg.position == "right" then
      vim.api.nvim_win_set_option(M._review_window, "winfixwidth", true)
    else
      vim.api.nvim_win_set_option(M._review_window, "winfixheight", true)
    end

    -- Return to previous window
    vim.cmd("wincmd p")
  end
  update_sidebar_selection()

  -- Call callback if provided
  if callback then
    callback()
  end
end

-- Refresh review buffer (call when files are marked as viewed)
function M.refresh_review_buffer()
  if M._review_buffer and vim.api.nvim_buf_is_valid(M._review_buffer) then
    -- Update viewed status in files list
    for _, file in ipairs(M._review_files) do
      file.viewed = is_file_viewed(file.path)
    end
    render_review_buffer()
  end
end

-- Toggle review buffer (open/close)
function M.toggle_review_buffer()
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Check if window is open
  if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
    -- Close it
    vim.api.nvim_win_close(M._review_window, true)
    M._review_window = nil
  else
    -- Open it
    M.open_review_buffer()
  end
end

-- Setup global navigation keymaps (work during review mode only)
local function setup_global_review_keymaps()
  -- File navigation keymaps (global, but only work in review mode)
  vim.keymap.set("n", M.config.next_file_key, function()
    if vim.g.pr_review_number then
      M.next_file()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.next_file_key, true, false, true), "n", false)
    end
  end, { desc = "Go to next file (PR review mode)" })

  vim.keymap.set("n", M.config.prev_file_key, function()
    if vim.g.pr_review_number then
      M.prev_file()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.prev_file_key, true, false, true), "n", false)
    end
  end, { desc = "Go to previous file (PR review mode)" })

  -- Commit mode keymaps (global, but only work in review mode)
  local commit_keys = {
    { M.config.commit_mode_toggle_key, function() M.toggle_commit_mode() end, "Toggle PR / commit review mode" },
    { M.config.next_commit_key, function() M.next_commit() end, "Go to next commit (PR review mode)" },
    { M.config.prev_commit_key, function() M.prev_commit() end, "Go to previous commit (PR review mode)" },
  }
  for _, k in ipairs(commit_keys) do
    local key, fn, desc = k[1], k[2], k[3]
    if key then
      vim.keymap.set("n", key, function()
        if vim.g.pr_review_number then
          fn()
        else
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
        end
      end, { desc = desc })
    end
  end

  -- Toggle review buffer
  vim.keymap.set("n", M.config.review_buffer.toggle_key, function()
    if vim.g.pr_review_number then
      M.toggle_review_buffer()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.review_buffer.toggle_key, true, false, true), "n",
        false)
    end
  end, { desc = "Toggle review buffer (PR review mode)" })
end

update_changes_float = function()
  if not vim.g.pr_review_number then
    close_float_wins()
    return
  end

  -- Don't show floats if disabled in config
  if not M.config.show_floats then
    close_float_wins()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Get file position from review files (use ordered list if available)
  local file_path = get_relative_path(bufnr)
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files
  local file_idx = nil
  local total_files = #file_list
  local file_status = "M" -- default
  local stats = nil

  for i, file in ipairs(file_list) do
    if file.path == file_path then
      file_idx = i
      file_status = file.status
      stats = file.stats
      break
    end
  end

  -- Only show floats for files that are part of the review
  if not file_idx then
    close_float_wins()
    return
  end

  local comments = M._buffer_comments[bufnr]
  local comment_count = comments and #comments or 0
  local is_viewed = is_file_viewed(file_path)

  -- FLOAT 1: General info (file x/total)
  local general_lines = {}
  if M.config.show_icons then
    table.insert(general_lines, string.format(" 📁 File %d/%d ", file_idx, total_files))
  else
    table.insert(general_lines, string.format(" File %d/%d ", file_idx, total_files))
  end
  local commit, commit_idx = current_commit()
  if commit then
    table.insert(general_lines, string.format(" Commit %d/%d %s ", commit_idx, #M._commits, commit.change))
  end

  -- FLOAT 2: Buffer info (viewed, hunks, stats, comments)
  local buffer_lines = {}
  if M.config.show_icons then
    local viewed_icon = is_viewed and "✓" or "○"
    table.insert(buffer_lines, string.format(" %s %s ", viewed_icon, is_viewed and "Viewed" or "Not viewed"))
  else
    table.insert(buffer_lines, string.format(" [%s] ", is_viewed and "Viewed" or "Not viewed"))
  end
  if stats then
    table.insert(buffer_lines, string.format(" +%d ~%d -%d ", stats.additions, stats.modifications, stats.deletions))
  end
  if comment_count > 0 then
    if M.config.show_icons then
      table.insert(buffer_lines, string.format(" 💬 %d comments ", comment_count))
    else
      table.insert(buffer_lines, string.format(" %d comments ", comment_count))
    end
  end

  -- FLOAT 3: Keymaps
  local keymap_lines = {}
  table.insert(keymap_lines, string.format(" %s: Next file ", M.config.next_file_key))
  table.insert(keymap_lines, string.format(" %s: Prev file ", M.config.prev_file_key))
  table.insert(keymap_lines, string.format(" %s: Mark viewed ", M.config.mark_as_viewed_key))
  table.insert(keymap_lines, string.format(" %s: Toggle floats ", M.config.toggle_floats_key))
  table.insert(keymap_lines, string.format(" %s: %s ", M.config.commit_mode_toggle_key,
    M._commit_mode and "Review whole PR" or "Review commits"))
  table.insert(keymap_lines, string.format(" %s: Next commit ", M.config.next_commit_key))
  table.insert(keymap_lines, string.format(" %s: Prev commit ", M.config.prev_commit_key))

  -- Helper to create/update float
  local function create_or_update_float(win_var, lines, row_offset, highlight)
    local max_width = 0
    for _, line in ipairs(lines) do
      if #line > max_width then
        max_width = #line
      end
    end

    local buf
    if win_var and vim.api.nvim_win_is_valid(win_var) then
      buf = vim.api.nvim_win_get_buf(win_var)
    else
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    if not win_var or not vim.api.nvim_win_is_valid(win_var) then
      local new_win = vim.api.nvim_open_win(buf, false, {
        relative = "win",
        anchor = "NE",
        width = max_width,
        height = #lines,
        row = row_offset,
        col = vim.api.nvim_win_get_width(0),
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 50,
      })
      vim.api.nvim_set_option_value("winhl", highlight, { win = new_win })
      return new_win
    else
      vim.api.nvim_win_set_config(win_var, {
        relative = "win",
        anchor = "NE",
        width = max_width,
        height = #lines,
        row = row_offset,
        col = vim.api.nvim_win_get_width(0),
      })
      return win_var
    end
  end

  -- Create the 3 floats stacked vertically
  -- Use red border for deleted files
  local border_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or
      "Normal:DiagnosticInfo,FloatBorder:DiagnosticInfo"
  M._float_win_general = create_or_update_float(M._float_win_general, general_lines, 0, border_hl)

  local general_height = #general_lines + 2 -- +2 for border
  local buffer_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or
      "Normal:DiagnosticHint,FloatBorder:DiagnosticHint"
  M._float_win_buffer = create_or_update_float(M._float_win_buffer, buffer_lines, general_height, buffer_hl)

  local buffer_height = #buffer_lines + 2
  local keymap_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or
      "Normal:DiagnosticWarn,FloatBorder:DiagnosticWarn"
  M._float_win_keymaps = create_or_update_float(M._float_win_keymaps, keymap_lines, general_height + buffer_height,
    keymap_hl)
end

function M.mark_file_as_viewed_and_next()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = get_relative_path(bufnr)

  -- Toggle viewed status (only for this commit's changes in commit mode)
  local now_viewed = not is_file_viewed(file_path)
  set_file_viewed(file_path, now_viewed)

  -- Save session
  save_session()

  -- Update the float to show new status
  update_changes_float()

  -- Update review buffer
  M.refresh_review_buffer()

  -- Only go to next file if we just marked it as viewed (not when unmarking)
  if now_viewed then
    M.next_file()
  end
end

function M.next_file()
  -- Prevent concurrent file navigation operations
  if M._opening_file then
    return
  end

  -- Use ordered list from ReviewBuffer
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files

  if not vim.g.pr_review_number or #file_list == 0 then
    return
  end

  local current_file = get_relative_path(vim.api.nvim_get_current_buf())
  local current_idx = nil

  for i, file in ipairs(file_list) do
    if file.path == current_file then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Open first file
    if file_list[1] then
      open_file_safe(file_list[1], nil)
    end
    return
  end

  if current_idx >= #file_list then
    vim.notify("Already at the last file", vim.log.levels.INFO)
    return
  end

  M._opening_file = true
  local next_file = file_list[current_idx + 1]

  open_file_safe(next_file, nil)
  M._opening_file = false
end

function M.prev_file()
  -- Prevent concurrent file navigation operations
  if M._opening_file then
    return
  end

  -- Use ordered list from ReviewBuffer
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files

  if not vim.g.pr_review_number or #file_list == 0 then
    return
  end

  local current_file = get_relative_path(vim.api.nvim_get_current_buf())
  local current_idx = nil

  for i, file in ipairs(file_list) do
    if file.path == current_file then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Open first file
    if file_list[1] then
      open_file_safe(file_list[1], nil)
    end
    return
  end

  if current_idx <= 1 then
    vim.notify("Already at the first file", vim.log.levels.INFO)
    return
  end

  M._opening_file = true
  local prev_file = file_list[current_idx - 1]

  open_file_safe(prev_file, nil)
  M._opening_file = false
end

local function load_changes_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.g.pr_review_number then
    return
  end

  local file_path = get_relative_path(bufnr)

  -- Only files that are part of the review (diffs themselves are shown by git tools, e.g. gitsigns)
  local status = nil
  for _, file in ipairs(M._review_files) do
    if file.path == file_path then
      status = file.status
      break
    end
  end
  if not status then
    return
  end

  -- Setup buffer-local keymaps for review files (only once per buffer)
  if not M._buffer_keymaps_saved[bufnr] then
    vim.keymap.set("n", M.config.mark_as_viewed_key, M.mark_file_as_viewed_and_next,
      { buffer = bufnr, desc = "Mark as viewed and next" })
    vim.keymap.set("n", M.config.toggle_floats_key, M.toggle_floats,
      { buffer = bufnr, desc = "Toggle floating windows" })
    M._buffer_keymaps_saved[bufnr] = true
  end

  -- Changed lines: needed to validate comment lines and to jump to the first change
  get_changed_lines_for_file(file_path, status, function(lines, hunks)
    -- The buffer may be gone by the time the diff arrives (e.g. review cleanup)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.g.pr_review_number then
      return
    end
    if lines and #lines > 0 then
      M._buffer_changes[bufnr] = lines
      M._buffer_hunks[bufnr] = hunks
    else
      M._buffer_changes[bufnr] = nil
      M._buffer_hunks[bufnr] = nil
    end
    if bufnr == vim.api.nvim_get_current_buf() then
      update_changes_float()
    end
  end)
end

local function count_comments_at_line(comments, line)
  local count = 0
  for _, comment in ipairs(comments) do
    if comment.line == line then
      count = count + 1
    end
  end
  return count
end

-- Map GitHub reaction content to emoji
local reaction_emoji_map = {
  ["+1"] = "👍",
  ["-1"] = "👎",
  ["laugh"] = "😄",
  ["confused"] = "😕",
  ["heart"] = "❤️",
  ["hooray"] = "🎉",
  ["rocket"] = "🚀",
  ["eyes"] = "👀",
}

-- Format reactions for a single comment
local function format_comment_reactions(comment)
  if not comment.reactions or type(comment.reactions) ~= "table" or #comment.reactions == 0 then
    return ""
  end

  -- Count reactions by type
  local reaction_counts = {}
  for _, reaction in ipairs(comment.reactions) do
    if reaction and reaction.content and type(reaction.content) == "string" then
      local emoji = reaction_emoji_map[reaction.content] or reaction.content
      reaction_counts[emoji] = (reaction_counts[emoji] or 0) + 1
    end
  end

  -- Format as "emoji count" pairs
  local parts = {}
  for emoji, count in pairs(reaction_counts) do
    if count > 1 then
      table.insert(parts, string.format("%s %d", emoji, count))
    else
      table.insert(parts, emoji)
    end
  end

  if #parts > 0 then
    return table.concat(parts, " ")
  end
  return ""
end

-- Format reactions for a line
local function format_reactions_for_line(comments, line)
  -- Collect all reactions from all comments on this line
  local reaction_counts = {}
  for _, comment in ipairs(comments) do
    if comment.line == line and comment.reactions and type(comment.reactions) == "table" then
      for _, reaction in ipairs(comment.reactions) do
        -- Add nil checks to prevent errors with malformed reaction data
        if reaction and reaction.content and type(reaction.content) == "string" then
          local emoji = reaction_emoji_map[reaction.content] or reaction.content
          reaction_counts[emoji] = (reaction_counts[emoji] or 0) + 1
        end
      end
    end
  end

  -- Format as "emoji count" pairs
  local parts = {}
  for emoji, count in pairs(reaction_counts) do
    if count > 1 then
      table.insert(parts, string.format("%s %d", emoji, count))
    else
      table.insert(parts, emoji)
    end
  end

  if #parts > 0 then
    return " " .. table.concat(parts, " ")
  end
  return ""
end

local function display_comments(bufnr, comments)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines_with_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line and type(comment.line) == "number" and comment.line > 0 then
      lines_with_comments[comment.line] = true
    end
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for line, _ in pairs(lines_with_comments) do
    local line_idx = line - 1
    if line_idx < line_count then
      local count = count_comments_at_line(comments, line)

      -- Check if any comment on this line is part of the pending review
      local has_pending = false
      for _, c in ipairs(comments) do
        if c.line == line and c.is_pending then
          has_pending = true
        end
      end

      local reactions_text = format_reactions_for_line(comments, line)

      local text
      if M.config.show_icons then
        if has_pending then
          text = count > 1 and string.format(" ⏳ %d comments (pending)", count) or " ⏳ 1 comment (pending)"
        else
          text = count > 1 and string.format(" 💬 %d comments", count) or " 💬 1 comment"
        end
      else
        if has_pending then
          text = count > 1 and string.format(" [%d comments (pending)]", count) or " [1 comment (pending)]"
        else
          text = count > 1 and string.format(" [%d comments]", count) or " [1 comment]"
        end
      end

      text = text .. reactions_text

      -- Keep the line's diff background when the buffer is in diff mode (e.g. :Gvdiffsplit)
      local line_bg = nil
      local diff_hl = vim.fn.diff_hlID(line, 1)
      if diff_hl > 0 then
        local hl_name = vim.fn.synIDattr(diff_hl, "name")
        if hl_name and hl_name ~= "" then
          line_bg = vim.api.nvim_get_hl(0, { name = hl_name, link = false }).bg
        end
      end

      -- Create custom highlight group for comment indicator
      local base_hl_name, custom_hl_name
      if has_pending then
        base_hl_name = "DiagnosticWarn"
        custom_hl_name = "PRCommentPending"
      else
        base_hl_name = "DiagnosticInfo"
        custom_hl_name = "PRCommentInfo"
      end
      local base_hl = vim.api.nvim_get_hl(0, { name = base_hl_name, link = false })

      -- Use line background, or fallback to Normal background if no diff
      local comment_bg = line_bg
      if not comment_bg then
        local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
        comment_bg = normal_hl.bg
      end

      vim.api.nvim_set_hl(0, custom_hl_name, {
        fg = base_hl.fg,
        bg = comment_bg,
      })

      -- Sign in the sign column (left, next to the git signs), so commented lines stand out
      local sign_text
      if M.config.show_icons then
        sign_text = has_pending and "⏳" or "💬"
      else
        sign_text = has_pending and "P" or "C"
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
        sign_text = sign_text,
        sign_hl_group = base_hl_name,
        virt_text = { { text, custom_hl_name } },
        virt_text_pos = M.config.comment_indicator_position,
      })
    end
  end
end

function M.show_comments_at_cursor()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    return
  end

  local lines = {}
  for i, comment in ipairs(line_comments) do
    if i > 1 then
      table.insert(lines, string.rep("─", 40))
    end
    if M.config.show_icons then
      table.insert(lines, string.format("👤 %s", comment.user))
    else
      table.insert(lines, string.format("@%s", comment.user))
    end
    table.insert(lines, "")
    for body_line in comment.body:gmatch("[^\r\n]+") do
      table.insert(lines, body_line)
    end

    -- Add reactions if present
    local reactions = format_comment_reactions(comment)
    if reactions ~= "" then
      table.insert(lines, "")
      table.insert(lines, reactions)
    end
  end

  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focus_id = "pr_review_comment",
    max_width = 80,
    max_height = 20,
  })
end

-- Helper function to select emoji and add/remove reaction
local function select_and_add_reaction(pr_number, comment, bufnr)
  -- First, get current user to check if they already reacted
  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    ui.select_emoji_reaction(function(reaction_content)
      if not reaction_content then
        return
      end

      -- Check if user already has this reaction on the comment
      local existing_reaction_id = nil
      if comment.reactions then
        for _, reaction in ipairs(comment.reactions) do
          if reaction.content == reaction_content and reaction.user == current_user then
            existing_reaction_id = reaction.id
            break
          end
        end
      end

      if existing_reaction_id then
        -- Remove the reaction
        github.remove_comment_reaction(comment.id, existing_reaction_id, function(success, remove_err)
          if success then
            vim.notify("Reaction removed!", vim.log.levels.INFO)
            -- Reload comments to show the updated reactions
            github.clear_cache()
            M.load_comments_for_buffer(bufnr, true)
          else
            vim.notify("Failed to remove reaction: " .. (remove_err or "unknown error"), vim.log.levels.ERROR)
          end
        end)
      else
        -- Add the reaction
        github.add_comment_reaction(comment.id, reaction_content, function(success, add_err)
          if success then
            vim.notify("Reaction added!", vim.log.levels.INFO)
            -- Reload comments to show the new reaction
            github.clear_cache()
            M.load_comments_for_buffer(bufnr, true)
          else
            vim.notify("Failed to add reaction: " .. (add_err or "unknown error"), vim.log.levels.ERROR)
          end
        end)
      end
    end)
  end)
end

-- Add emoji reaction to a comment at cursor line
function M.add_reaction_to_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in a PR review", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments on this file", vim.log.levels.INFO)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line and not comment.is_pending then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    vim.notify("No posted comments on this line", vim.log.levels.INFO)
    return
  end

  -- If multiple comments on the line, let user select which one
  local target_comment
  if #line_comments == 1 then
    target_comment = line_comments[1]
  else
    local items = {}
    for i, comment in ipairs(line_comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 60)
      if #comment.body > 60 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("%d. @%s: %s", i, comment.user, preview))
    end

    vim.ui.select(items, {
      prompt = "Select comment to react to:",
    }, function(_, idx)
      if idx then
        target_comment = line_comments[idx]
        select_and_add_reaction(pr_number, target_comment, bufnr)
      end
    end)
    return
  end

  select_and_add_reaction(pr_number, target_comment, bufnr)
end

function M.load_comments_for_buffer(bufnr, force_reload)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M.config.show_comments then
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    return
  end

  if force_reload then
    github.clear_cache()
  end

  local file_path = get_relative_path(bufnr)

  local function show(comments)
    if comments and #comments > 0 then
      M._buffer_comments[bufnr] = comments
      -- Use defer_fn with a delay to ensure diff highlights are applied first
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          display_comments(bufnr, comments)
        end
      end, 50)
    else
      M._buffer_comments[bufnr] = nil
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
        end
      end)
    end
  end

  -- Get regular comments
  github.get_comments_for_file(pr_number, file_path, function(comments, err)
    if err then
      return
    end

    -- Initialize comments if nil
    if not comments then
      comments = {}
    end

    -- Commit mode: only comments made on this commit, at their line in this commit
    local commit = current_commit()
    if commit then
      local commit_comments = {}
      for _, c in ipairs(comments) do
        if c.original_commit_id == commit.id then
          table.insert(commit_comments, vim.tbl_extend("force", {}, c, { line = c.original_line or c.line }))
        end
      end
      show(commit_comments)
      return
    end

    -- Also get the comments of the pending review and merge them
    github.get_pending_review_comments(pr_number, function(pending_comments, pending_err)
      if not pending_err and pending_comments then
        local pending_ids = {}
        for _, pc in ipairs(pending_comments) do
          pending_ids[pc.id] = true
        end
        comments = vim.tbl_filter(function(c)
          return not pending_ids[c.id]
        end, comments)
        for _, pc in ipairs(pending_comments) do
          if pc.path == file_path then
            table.insert(comments, pc)
          end
        end
      end

      show(comments)
    end)
  end)
end

-- Draft management functions
local function get_draft_key(pr_number, file_path, line, action, comment_id)
  -- Create unique key for draft: pr_number:file:line:action[:comment_id]
  local key = string.format("%d:%s:%d:%s", pr_number, file_path or "", line or 0, action)
  if comment_id then
    key = key .. ":" .. tostring(comment_id)
  end
  return key
end

local function save_draft(pr_number, file_path, line, action, comment_id, text)
  if not text or text == "" then
    return
  end
  local key = get_draft_key(pr_number, file_path, line, action, comment_id)
  if not M._drafts[pr_number] then
    M._drafts[pr_number] = {}
  end
  M._drafts[pr_number][key] = {
    text = text,
    timestamp = os.time(),
    file_path = file_path,
    line = line,
    action = action,
    comment_id = comment_id,
  }
  save_session()
end

local function get_draft(pr_number, file_path, line, action, comment_id)
  local key = get_draft_key(pr_number, file_path, line, action, comment_id)
  if M._drafts[pr_number] and M._drafts[pr_number][key] then
    return M._drafts[pr_number][key].text
  end
  return nil
end

local function clear_draft(pr_number, file_path, line, action, comment_id)
  local key = get_draft_key(pr_number, file_path, line, action, comment_id)
  if M._drafts[pr_number] then
    M._drafts[pr_number][key] = nil
  end
  save_session()
end

-- A comment window was submitted with text: clear its draft, and return restore_draft(), which saves
-- the text back as the draft. Callers call it when sending fails, so the text survives (e.g. a
-- network error) and comes back the next time the same comment window opens.
local function take_draft(draft_info, pr_number, text)
  if not (draft_info and pr_number and text ~= "") then
    return function() end
  end
  clear_draft(pr_number, draft_info.file_path, draft_info.line, draft_info.action, draft_info.comment_id)
  return function()
    save_draft(pr_number, draft_info.file_path, draft_info.line, draft_info.action, draft_info.comment_id, text)
    vim.notify("Your text is kept as a draft: open the same comment window again to retry", vim.log.levels.WARN)
  end
end

local function input_multiline(prompt, callback, initial_text, draft_info)
  -- draft_info: { pr_number, file_path, line, action, comment_id }
  local pr_number = vim.g.pr_review_number

  -- Check if there's a saved draft
  if draft_info and pr_number then
    local draft_text = get_draft(
      pr_number,
      draft_info.file_path,
      draft_info.line,
      draft_info.action,
      draft_info.comment_id
    )
    if draft_text and (not initial_text or initial_text == "") then
      initial_text = draft_text
      prompt = prompt .. " [DRAFT RESTORED]"
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Set initial text if provided
  local has_initial_text = false
  if initial_text then
    local lines = vim.split(initial_text, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- Move cursor to the end
    local last_line = #lines
    vim.api.nvim_win_set_cursor(win, { last_line, 0 })
    has_initial_text = true
  end

  -- Save draft function
  local function save_current_draft()
    if draft_info and pr_number then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      if text and text ~= "" then
        save_draft(
          pr_number,
          draft_info.file_path,
          draft_info.line,
          draft_info.action,
          draft_info.comment_id,
          text
        )
      end
    end
  end

  vim.keymap.set("n", "<Esc>", function()
    save_current_draft()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")

    local restore_draft = take_draft(draft_info, pr_number, text)

    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    if text ~= "" then
      callback(text, restore_draft)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Auto-save draft when window is closed unexpectedly
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- Only save if buffer still exists and window was closed
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_win_is_valid(win) then
          save_current_draft()
        end
      end, 10)
    end,
  })

  -- Enter insert mode automatically
  if has_initial_text then
    vim.cmd("startinsert!")  -- Append at end of line
  else
    vim.cmd("startinsert")
  end
end

-- Show pending comments in a preview buffer
local function show_pending_comments_preview(pending_comments, callback)
  if not pending_comments or #pending_comments == 0 then
    callback(true) -- No comments, proceed
    return
  end

  -- Build content first to calculate height
  local lines = {}
  table.insert(lines, "These pending comments will be submitted with your review:")
  table.insert(lines, "")

  for i, comment in ipairs(pending_comments) do
    table.insert(lines, string.format("━━━ Comment %d (PENDING) ━━━", i))
    -- Outdated comments (their line changed since) have no line
    table.insert(lines, comment.line and string.format("📄 %s:%d", comment.path, comment.line)
      or string.format("📄 %s (outdated)", comment.path))
    table.insert(lines, "")

    -- Add comment body with wrapping
    for line in comment.body:gmatch("[^\r\n]+") do
      table.insert(lines, "  " .. line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  table.insert(lines, "")
  table.insert(lines, "Press 'y' to proceed, 'n' to cancel, 'q' to cancel")

  -- Calculate window dimensions
  local width = math.floor(vim.o.columns * 0.8)
  local content_height = #lines
  local max_height = math.min(math.floor(vim.o.lines * 0.7), 25) -- Max 70% of screen or 25 lines
  local height = math.min(content_height, max_height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format(" %d Pending Comment%s - y: proceed | n/q: cancel ", #pending_comments,
      #pending_comments > 1 and "s" or ""),
    title_pos = "center",
  })

  -- Position cursor at the bottom to show the prompt
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })

  -- Set up keymaps
  local function close_and_respond(proceed)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    callback(proceed)
  end

  vim.keymap.set("n", "y", function() close_and_respond(true) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "n", function() close_and_respond(false) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", function() close_and_respond(false) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function() close_and_respond(false) end, { buffer = buf, nowait = true })
end

-- After approving, the review is usually done: offer to exit and clean it up
local function offer_exit_after_approve(pr_number)
  vim.schedule(function()
    local choice = vim.fn.confirm(string.format("PR #%d approved. Exit the review and clean it up?", pr_number),
      "&Yes\n&No", 1)
    if choice == 1 then
      M.cleanup_review_branch({ confirmed = true })
    end
  end)
end

function M.approve_pr()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.get_pending_review_comments(pr_number, function(pending_comments, pending_err)
    if pending_err then
      vim.notify("❌ Failed to fetch pending comments: " .. pending_err, vim.log.levels.ERROR)
      return
    end
    show_pending_comments_preview(pending_comments, function(proceed)
      if not proceed then
        vim.notify("Approval cancelled", vim.log.levels.INFO)
        return
      end

      input_multiline("Approval comment (optional)", function(body, restore_draft)
        vim.notify("Approving PR #" .. pr_number .. "...", vim.log.levels.INFO)
        submit_review(pr_number, "APPROVE", body, github.approve_pr, function(ok, err)
          if ok then
            vim.notify(string.format("✅ PR #%d approved%s", pr_number,
              #pending_comments > 0 and string.format(" with %d comments!", #pending_comments) or "!"),
              vim.log.levels.INFO)
            offer_exit_after_approve(pr_number)
          else
            vim.notify("❌ Failed to approve: " .. (err or "unknown"), vim.log.levels.ERROR)
            restore_draft()
          end
        end)
      end, nil, {
        pr_number = pr_number,
        file_path = nil,
        line = nil,
        action = "approve_pr",
      })
    end)
  end)
end

function M.request_changes()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.get_pending_review_comments(pr_number, function(pending_comments, pending_err)
    if pending_err then
      vim.notify("❌ Failed to fetch pending comments: " .. pending_err, vim.log.levels.ERROR)
      return
    end
    show_pending_comments_preview(pending_comments, function(proceed)
      if not proceed then
        vim.notify("Request changes cancelled", vim.log.levels.INFO)
        return
      end

      input_multiline("Reason for requesting changes (required by GitHub)", function(body, restore_draft)
        if not body or body:match("^%s*$") then
          vim.notify("❌ Reason is required when requesting changes (GitHub requirement)", vim.log.levels.ERROR)
          return
        end
        vim.notify("Requesting changes on PR #" .. pr_number .. "...", vim.log.levels.INFO)
        submit_review(pr_number, "REQUEST_CHANGES", body, github.request_changes, function(ok, err)
          if ok then
            vim.notify(string.format("✅ Requested changes on PR #%d%s", pr_number,
              #pending_comments > 0 and string.format(" with %d comments", #pending_comments) or ""),
              vim.log.levels.INFO)
          else
            vim.notify("❌ Failed to request changes: " .. (err or "unknown"), vim.log.levels.ERROR)
            restore_draft()
          end
        end)
      end, nil, {
        pr_number = pr_number,
        file_path = nil,
        line = nil,
        action = "request_changes",
      })
    end)
  end)
end

function M.submit_pending_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.get_pending_review_comments(pr_number, function(pending_comments, pending_err)
    if pending_err then
      vim.notify("❌ Failed to fetch pending comments: " .. pending_err, vim.log.levels.ERROR)
      return
    end
    if #pending_comments == 0 then
      vim.notify("No pending comments to submit", vim.log.levels.INFO)
      return
    end

    show_pending_comments_preview(pending_comments, function(proceed)
      if not proceed then
        vim.notify("Submission cancelled", vim.log.levels.INFO)
        return
      end

      input_multiline("Optional comment for review (can be empty)", function(body, restore_draft)
        vim.notify(string.format("Submitting %d pending comment(s)...", #pending_comments), vim.log.levels.INFO)
        submit_review(pr_number, "COMMENT", body or "", nil, function(ok, err)
          if ok then
            vim.notify(string.format("✅ Submitted %d comment(s) successfully!", #pending_comments),
              vim.log.levels.INFO)
          else
            vim.notify("❌ Failed to submit comments: " .. (err or "unknown"), vim.log.levels.ERROR)
            restore_draft()
          end
        end)
      end, nil, {
        pr_number = pr_number,
        file_path = nil,
        line = nil,
        action = "submit_pending",
      })
    end)
  end)
end

function M.add_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  input_multiline("PR Comment", function(body, restore_draft)
    if not body then
      return
    end
    vim.notify("Adding comment...", vim.log.levels.INFO)
    github.add_pr_comment(pr_number, body, function(ok, err)
      if ok then
        vim.notify("✅ Comment added to PR #" .. pr_number, vim.log.levels.INFO)
      else
        vim.notify("❌ Failed to add comment: " .. (err or "unknown"), vim.log.levels.ERROR)
        restore_draft()
      end
    end)
  end, nil, {
    pr_number = pr_number,
    file_path = nil,
    line = nil,
    action = "add_pr_comment",
  })
end

-- Build a comment thread by following in_reply_to_id
local function build_comment_thread(target_comment, all_comments)
  local thread = {}
  local comment_map = {}

  -- Build a map of comment_id -> comment
  for _, c in ipairs(all_comments) do
    comment_map[c.id] = c
  end

  -- Find the root of the thread
  local root = target_comment
  while root.in_reply_to_id and comment_map[root.in_reply_to_id] do
    root = comment_map[root.in_reply_to_id]
  end

  -- Build the thread from root to current
  local function collect_thread(comment, depth)
    depth = depth or 0
    table.insert(thread, { comment = comment, depth = depth })

    -- Find all replies to this comment
    for _, c in ipairs(all_comments) do
      if c.in_reply_to_id == comment.id then
        collect_thread(c, depth + 1)
      end
    end
  end

  collect_thread(root, 0)
  return thread
end

-- Wrap text to fit within a given width
local function wrap_text(text, max_width, indent)
  indent = indent or ""
  local indent_len = #indent
  local available_width = max_width - indent_len

  if available_width <= 0 then
    available_width = 40 -- fallback minimum
  end

  local wrapped_lines = {}

  -- Split by existing line breaks first
  for paragraph in text:gmatch("[^\r\n]+") do
    local current_line = ""

    -- Split paragraph into words
    for word in paragraph:gmatch("%S+") do
      local test_line = current_line == "" and word or (current_line .. " " .. word)

      if #test_line <= available_width then
        current_line = test_line
      else
        -- Current line is full, save it and start new line
        if current_line ~= "" then
          table.insert(wrapped_lines, indent .. current_line)
        end
        current_line = word
      end
    end

    -- Add remaining text
    if current_line ~= "" then
      table.insert(wrapped_lines, indent .. current_line)
    end
  end

  return wrapped_lines
end

-- Input reply with conversation context
-- Input new comment with conversation context (like reply but for new comments)
local function input_comment_with_context(target_comment, all_comments, prompt_title, callback, draft_info)
  -- draft_info: { pr_number, file_path, line, action, comment_id }
  local pr_number = vim.g.pr_review_number

  -- Check if there's a saved draft
  local draft_text = nil
  if draft_info and pr_number then
    draft_text = get_draft(
      pr_number,
      draft_info.file_path,
      draft_info.line,
      draft_info.action,
      draft_info.comment_id
    )
    if draft_text then
      prompt_title = prompt_title .. " [DRAFT RESTORED]"
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt_title .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Build the thread
  local thread = build_comment_thread(target_comment, all_comments)

  -- Format the thread
  local lines = {}
  table.insert(lines, "--- Conversation Thread ---")
  table.insert(lines, "")

  for _, item in ipairs(thread) do
    local indent = string.rep("  ", item.depth)
    local prefix = item.depth > 0 and "↳ " or ""

    -- Add author and date
    local date = item.comment.created_at or ""
    if date ~= "" then
      date = " (" .. date:sub(1, 10) .. ")"
    end

    -- Add pending indicator if it's a local pending comment
    local pending_mark = item.comment.is_pending and " [PENDING]" or ""

    table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. pending_mark .. ":")

    -- Add comment body with word wrap and indent
    local wrapped = wrap_text(item.comment.body, width - 4, indent)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(lines, wrapped_line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "--- Answer here: ---")
  table.insert(lines, "")

  -- Add draft text if exists
  if draft_text then
    for draft_line in draft_text:gmatch("[^\r\n]+") do
      table.insert(lines, draft_line)
    end
  end

  local separator_line = #lines - (draft_text and vim.tbl_count(vim.split(draft_text, "\n")) or 1)

  -- Set the content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Make everything above separator read-only by setting it as not modifiable initially
  vim.bo[buf].modifiable = true

  -- Create namespace for highlighting
  local ns_id = vim.api.nvim_create_namespace("comment_context")

  -- Highlight the separator
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", separator_line - 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)

  -- Save draft function
  local function save_current_draft()
    if draft_info and pr_number then
      local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Extract only the lines after the separator
      local comment_lines = {}
      local found_separator = false
      for i, line in ipairs(all_lines) do
        if line:match("^%-%-%-+ Answer here:") then
          found_separator = true
        elseif found_separator and line ~= "" then
          table.insert(comment_lines, line)
        end
      end

      local text = table.concat(comment_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if text and text ~= "" then
        save_draft(
          pr_number,
          draft_info.file_path,
          draft_info.line,
          draft_info.action,
          draft_info.comment_id,
          text
        )
      end
    end
  end

  vim.keymap.set("n", "<Esc>", function()
    save_current_draft()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Extract only the lines after the separator
    local comment_lines = {}
    local found_separator = false
    for i, line in ipairs(all_lines) do
      if line:match("^%-%-%-+ Answer here:") then
        found_separator = true
      elseif found_separator and line ~= "" then
        table.insert(comment_lines, line)
      end
    end

    local text = table.concat(comment_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

    local restore_draft = take_draft(draft_info, pr_number, text)

    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")

    if text ~= "" then
      callback(text, restore_draft)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Auto-save draft when window is closed unexpectedly
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- Only save if buffer still exists and window was closed
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_win_is_valid(win) then
          save_current_draft()
        end
      end, 10)
    end,
  })

  -- Position cursor at the answer section
  if draft_text then
    -- If draft exists, position cursor at the end of the text
    local last_line = #lines
    vim.api.nvim_win_set_cursor(win, { last_line, 0 })
  else
    -- No draft, position at the start of answer section
    vim.api.nvim_win_set_cursor(win, { separator_line + 1, 0 })
  end

  -- Enter insert mode automatically
  if draft_text then
    vim.cmd("startinsert!")  -- Append at end of line
  else
    vim.cmd("startinsert")
  end
end

-- Show thread before adding/editing comment (deprecated - use input_comment_with_context instead)
local function show_reply_thread(target_comment, all_comments, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Conversation Thread (press Enter to continue, Esc to cancel) ",
    title_pos = "center",
  })

  -- Build the thread
  local thread = build_comment_thread(target_comment, all_comments)

  -- Format the thread
  local lines = {}
  table.insert(lines, "--- Conversation Thread ---")
  table.insert(lines, "")

  for _, item in ipairs(thread) do
    local indent = string.rep("  ", item.depth)
    local prefix = item.depth > 0 and "↳ " or ""

    -- Add author and date
    local date = item.comment.created_at or ""
    if date ~= "" then
      date = " (" .. date:sub(1, 10) .. ")"
    end

    -- Add pending indicator if it's a local pending comment
    local pending_mark = item.comment.is_pending and " [PENDING]" or ""

    table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. pending_mark .. ":")

    -- Add comment body with word wrap and indent
    local wrapped = wrap_text(item.comment.body, width - 4, indent)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(lines, wrapped_line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "")
  table.insert(lines, "Press Enter to continue or Esc to cancel")

  -- Set the content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Set buffer options AFTER setting content
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  -- Create namespace for highlighting
  local ns_id = vim.api.nvim_create_namespace("thread_preview")
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)

  local function close_and_continue()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if callback then
      callback()
    end
  end

  local function close_and_cancel()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  vim.keymap.set("n", "<CR>", close_and_continue, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_and_cancel, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", close_and_cancel, { buffer = buf, nowait = true })
end

local function input_reply_with_context(target_comment, all_comments, callback, draft_info)
  -- draft_info: { pr_number, file_path, line, action, comment_id }
  local pr_number = vim.g.pr_review_number
  local prompt_title = "Reply to " .. target_comment.user

  -- Check if there's a saved draft
  local draft_text = nil
  if draft_info and pr_number then
    draft_text = get_draft(
      pr_number,
      draft_info.file_path,
      draft_info.line,
      draft_info.action,
      draft_info.comment_id
    )
    if draft_text then
      prompt_title = prompt_title .. " [DRAFT RESTORED]"
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt_title .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Build the thread
  local thread = build_comment_thread(target_comment, all_comments)

  -- Format the thread
  local lines = {}
  table.insert(lines, "--- Conversation Thread ---")
  table.insert(lines, "")

  for _, item in ipairs(thread) do
    local indent = string.rep("  ", item.depth)
    local prefix = item.depth > 0 and "↳ " or ""

    -- Add author and date
    local date = item.comment.created_at or ""
    if date ~= "" then
      date = " (" .. date:sub(1, 10) .. ")"
    end
    table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. ":")

    -- Add comment body with word wrap and indent
    local wrapped = wrap_text(item.comment.body, width - 4, indent) -- -4 for border
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(lines, wrapped_line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "--- Answer here: ---")
  table.insert(lines, "")

  -- Add draft text if exists
  if draft_text then
    for draft_line in draft_text:gmatch("[^\r\n]+") do
      table.insert(lines, draft_line)
    end
  end

  local separator_line = #lines - (draft_text and vim.tbl_count(vim.split(draft_text, "\n")) or 1)

  -- Set the content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Make everything above separator read-only by setting it as not modifiable initially
  vim.bo[buf].modifiable = true

  -- Create namespace for highlighting
  local ns_id = vim.api.nvim_create_namespace("reply_context")

  -- Highlight the separator
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", separator_line - 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)

  -- Save draft function
  local function save_current_draft()
    if draft_info and pr_number then
      local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Extract only the lines after the separator
      local reply_lines = {}
      local found_separator = false
      for i, line in ipairs(all_lines) do
        if line:match("^%-%-%-+ Answer here:") then
          found_separator = true
        elseif found_separator and line ~= "" then
          table.insert(reply_lines, line)
        end
      end

      local text = table.concat(reply_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if text and text ~= "" then
        save_draft(
          pr_number,
          draft_info.file_path,
          draft_info.line,
          draft_info.action,
          draft_info.comment_id,
          text
        )
      end
    end
  end

  vim.keymap.set("n", "<Esc>", function()
    save_current_draft()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Extract only the lines after the separator
    local reply_lines = {}
    local found_separator = false
    for i, line in ipairs(all_lines) do
      if line:match("^%-%-%-+ Answer here:") then
        found_separator = true
      elseif found_separator and line ~= "" then
        table.insert(reply_lines, line)
      end
    end

    local text = table.concat(reply_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

    local restore_draft = take_draft(draft_info, pr_number, text)

    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")

    if text ~= "" then
      callback(text, restore_draft)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Auto-save draft when window is closed unexpectedly
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- Only save if buffer still exists and window was closed
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_win_is_valid(win) then
          save_current_draft()
        end
      end, 10)
    end,
  })

  -- Position cursor at the answer section
  if draft_text then
    -- If draft exists, position cursor at the end of the text
    local last_line = #lines
    vim.api.nvim_win_set_cursor(win, { last_line, 0 })
  else
    -- No draft, position at the start of answer section
    vim.api.nvim_win_set_cursor(win, { separator_line + 1, 0 })
  end

  -- Enter insert mode automatically
  if draft_text then
    vim.cmd("startinsert!")  -- Append at end of line
  else
    vim.cmd("startinsert")
  end
end

function M.add_review_comment_with_selection()
  if not M._visual_selection then
    vim.notify("No visual selection captured", vim.log.levels.WARN)
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = M._visual_selection.start_line
  local end_line = M._visual_selection.end_line
  local file_path = get_relative_path(bufnr)
  local selected_text = M._visual_selection.text

  -- Format as GitHub suggested change
  -- https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request#adding-line-comments-to-a-pull-request
  local suggestion_text = "```suggestion\n" .. selected_text .. "\n```\n\n"

  -- Clear the selection after use
  local temp_selection = M._visual_selection
  M._visual_selection = nil

  -- Prompt for comment
  input_multiline(
    "Suggested change (edit the code above, line " .. temp_selection.start_line .. "-" .. temp_selection.end_line .. ")",
    function(body, restore_draft)
      if not body then
        return
      end

      vim.notify("Adding code suggestion...", vim.log.levels.INFO)
      github.add_review_comment(pr_number, file_path, end_line, body, function(ok, err)
        if ok then
          vim.notify("✅ Code suggestion added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to add suggestion: " .. (err or "unknown"), vim.log.levels.ERROR)
          restore_draft()
        end
      end, start_line)
    end, suggestion_text, {
      pr_number = pr_number,
      file_path = file_path,
      line = end_line,
      action = "add_review_suggestion",
    })
end

function M.add_pending_comment_with_selection()
  if M._commit_mode then
    vim.notify("Pending comments are only available when reviewing the whole PR (" ..
      M.config.commit_mode_toggle_key .. "). Add a single comment instead.", vim.log.levels.WARN)
    return
  end
  if not M._visual_selection then
    vim.notify("No visual selection captured", vim.log.levels.WARN)
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = M._visual_selection.start_line
  local end_line = M._visual_selection.end_line
  local file_path = get_relative_path(bufnr)
  local selected_text = M._visual_selection.text

  -- Format as GitHub suggested change
  local suggestion_text = "```suggestion\n" .. selected_text .. "\n```\n\n"

  -- Clear the selection after use
  local temp_selection = M._visual_selection
  M._visual_selection = nil

  -- Prompt for comment
  input_multiline(
    "Pending suggested change (edit the code above, line " ..
    temp_selection.start_line .. "-" .. temp_selection.end_line .. ")", function(body, restore_draft)
      if not body then
        return
      end

      add_pending_comment_to_github(bufnr, pr_number, file_path, end_line, body, start_line, restore_draft)
    end, suggestion_text, {
      pr_number = pr_number,
      file_path = file_path,
      line = end_line,
      action = "add_pending_suggestion",
    })
end

function M.add_review_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file_path = get_relative_path(bufnr)

  -- Check if line is part of the diff
  if not is_line_in_diff(bufnr, cursor_line) then
    vim.notify("❌ Cannot add comment: line " .. cursor_line .. " is not part of the diff", vim.log.levels.ERROR)
    return
  end

  -- Check if there are existing comments on this line
  local comments = M._buffer_comments[bufnr] or {}
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  -- Show thread if there are existing comments
  if #line_comments > 0 then
    input_comment_with_context(line_comments[1], comments, "Add review comment", function(body, restore_draft)
      if not body then
        return
      end
      vim.notify("Adding review comment...", vim.log.levels.INFO)
      github.add_review_comment(pr_number, file_path, cursor_line, body, function(ok, err)
        if ok then
          vim.notify("✅ Review comment added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to add review comment: " .. (err or "unknown"), vim.log.levels.ERROR)
          restore_draft()
        end
      end)
    end, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_review_comment",
      comment_id = line_comments[1].id,
    })
  else
    -- No existing comments, just prompt for input
    input_multiline("Review comment for line " .. cursor_line, function(body, restore_draft)
      if not body then
        return
      end
      vim.notify("Adding review comment...", vim.log.levels.INFO)
      github.add_review_comment(pr_number, file_path, cursor_line, body, function(ok, err)
        if ok then
          vim.notify("✅ Review comment added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to add review comment: " .. (err or "unknown"), vim.log.levels.ERROR)
          restore_draft()
        end
      end)
    end, nil, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_review_comment",
    })
  end
end

function M.add_pending_comment()
  if M._commit_mode then
    vim.notify("Pending comments are only available when reviewing the whole PR (" ..
      M.config.commit_mode_toggle_key .. "). Add a single comment instead.", vim.log.levels.WARN)
    return
  end
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file_path = get_relative_path(bufnr)

  -- Check if line is part of the diff
  if not is_line_in_diff(bufnr, cursor_line) then
    vim.notify("❌ Cannot add comment: line " .. cursor_line .. " is not part of the diff", vim.log.levels.ERROR)
    return
  end

  -- Check if there are existing comments on this line
  local comments = M._buffer_comments[bufnr] or {}
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  -- Show thread if there are existing comments
  if #line_comments > 0 then
    input_comment_with_context(line_comments[1], comments, "Add pending comment", function(body, restore_draft)
      if not body then
        return
      end
      add_pending_comment_to_github(bufnr, pr_number, file_path, cursor_line, body, nil, restore_draft)
    end, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_pending_thread",
      comment_id = line_comments[1].id,
    })
  else
    -- No existing comments, just prompt for input
    input_multiline("Pending comment for line " .. cursor_line .. " (will be posted with review)", function(body, restore_draft)
      if not body then
        return
      end
      add_pending_comment_to_github(bufnr, pr_number, file_path, cursor_line, body, nil, restore_draft)
    end, nil, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_pending",
      comment_id = nil,
    })
  end
end

function M.list_pending_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end
  github.get_pending_review_comments(pr_number, function(comments, err)
    if err then
      vim.notify("Failed to fetch pending comments: " .. err, vim.log.levels.ERROR)
      return
    end
    M._pick_pending_comment(comments)
  end)
end

-- Picker over the pending review's comments, jumping to the selected one
function M._pick_pending_comment(all_comments)
  if #all_comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  -- Use the UI picker to select a comment
  ui.select_pending_comment(all_comments, M.config.picker, function(selected_comment)
    if not selected_comment then
      return
    end

    -- Navigate to the file and line
    local file_path = selected_comment.path

    -- Try to find buffer with this file
    local found_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == review_path(file_path) then
        found_buf = buf
        break
      end
    end

    -- Open the file
    if found_buf then
      -- File is already open in a buffer, find or create a window for it
      local wins = vim.fn.win_findbuf(found_buf)
      if #wins > 0 then
        vim.api.nvim_set_current_win(wins[1])
      else
        vim.cmd("buffer " .. found_buf)
      end
    else
      -- Open the file
      vim.cmd("edit " .. vim.fn.fnameescape(review_path(file_path)))
    end

    -- Navigate to the line (outdated comments have none: their line changed since)
    if not selected_comment.line then
      vim.notify(file_path .. ": the comment is outdated (its line changed), edit or delete it on GitHub",
        vim.log.levels.WARN)
      return
    end
    vim.api.nvim_win_set_cursor(0, { math.min(selected_comment.line, vim.api.nvim_buf_line_count(0)), 0 })
    vim.cmd("normal! zz")
    vim.notify(string.format("Navigated to %s:%d", file_path, selected_comment.line), vim.log.levels.INFO)
  end)
end

function M.list_all_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Fetch ALL comments from GitHub API (not just cached ones), and the pending review's
  github.get_pending_review_comments(pr_number, function(pending_comments)
  github.fetch_pr_comments(pr_number, function(github_comments, err)
    if err then
      vim.notify("Failed to fetch PR comments: " .. err, vim.log.levels.ERROR)
      return
    end

    local all_comments = {}

    local pending_ids = {}
    for _, pc in ipairs(pending_comments or {}) do
      pending_ids[pc.id] = true
    end

    -- Add all GitHub comments (the pending review's ones once, as pending)
    for _, comment in ipairs(github_comments or {}) do
      -- Skip comments without line number (those are review-level comments)
      if comment.line and not pending_ids[comment.id] then
        table.insert(all_comments, {
          id = comment.id,
          path = comment.path,
          line = comment.line,
          user = comment.user,
          body = comment.body,
          created_at = comment.created_at,
          is_pending = false,
          bufnr = nil,
        })
      end
    end
    for _, pending in ipairs(pending_comments or {}) do
      if pending.line then
        table.insert(all_comments, {
          id = pending.id,
          path = pending.path,
          line = pending.line,
          user = "You (PENDING)",
          body = pending.body,
          created_at = pending.created_at,
          is_pending = true,
          bufnr = nil,
        })
      end
    end

    if #all_comments == 0 then
      vim.notify("No comments in this PR", vim.log.levels.INFO)
      return
    end

    -- Sort by file path, then line number
    table.sort(all_comments, function(a, b)
      if a.path ~= b.path then
        return a.path < b.path
      end
      return a.line < b.line
    end)

    -- Use the UI picker to select a comment
    ui.select_all_comments(all_comments, M.config.picker, function(selected_comment)
      if not selected_comment then
        return
      end

      -- Navigate to the file and line
      local file_path = selected_comment.path

      -- Try to find buffer with this file
      local found_buf = nil
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local buf_name = vim.api.nvim_buf_get_name(buf)
          -- Make path relative to cwd
          local cwd = review_root()
          if buf_name:sub(1, #cwd) == cwd then
            buf_name = buf_name:sub(#cwd + 2)
          end
          if buf_name == file_path then
            found_buf = buf
            break
          end
        end
      end

      -- Open the file
      if found_buf then
        -- File is already open in a buffer, find or create a window for it
        local wins = vim.fn.win_findbuf(found_buf)
        if #wins > 0 then
          vim.api.nvim_set_current_win(wins[1])
        else
          vim.cmd("buffer " .. found_buf)
        end
      else
        -- Open the file
        vim.cmd("edit " .. vim.fn.fnameescape(review_path(file_path)))
      end

      -- Navigate to the line
      vim.api.nvim_win_set_cursor(0, { selected_comment.line, 0 })
      vim.cmd("normal! zz")

      -- Show notification with comment info
      local status = selected_comment.is_pending and "PENDING" or "Posted"
      vim.notify(
        string.format("[%s] %s:%d - %s", status, file_path, selected_comment.line, selected_comment.user),
        vim.log.levels.INFO
      )
    end)
  end)
  end)
end

-- List and view global PR comments (issue comments, not line-specific)
function M.list_global_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.fetch_pr_global_comments(pr_number, function(comments, err)
    if err then
      vim.notify("Failed to fetch global comments: " .. err, vim.log.levels.ERROR)
      return
    end

    if #comments == 0 then
      vim.notify("No global comments in this PR", vim.log.levels.INFO)
      return
    end

    -- Use the UI picker to select a comment
    ui.select_global_comments(comments, M.config.picker, function(comment, index)
      if not comment then
        return
      end

      -- Show full comment in a floating window
      local lines = vim.split(comment.body, "\n")

      -- Add header
      table.insert(lines, 1, "")
      table.insert(lines, 1, string.format("By: %s", comment.user))
      table.insert(lines, 1, string.format("Comment #%d", index or 1))
      table.insert(lines, 2, string.format("Date: %s", comment.created_at))
      table.insert(lines, 3, "")
      table.insert(lines, 4, "───────────────────────────────")
      table.insert(lines, 5, "")

      -- Add footer with actions
      table.insert(lines, "")
      table.insert(lines, "───────────────────────────────")
      table.insert(lines, "")
      table.insert(lines, "Press 'r' to reply | 'q' or <Esc> to close")

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "markdown"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].modifiable = false

      local width = math.min(80, math.floor(vim.o.columns * 0.8))
      local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " Global Comment ",
        title_pos = "center",
      })

      -- Keymaps for the comment window
      local function close_window()
        -- Delete buffer first (will auto-close window due to bufhidden=wipe)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        -- Also try to close window if still valid
        pcall(vim.api.nvim_win_close, win, true)
      end

      vim.keymap.set("n", "q", close_window, { buffer = buf, nowait = true })
      vim.keymap.set("n", "<Esc>", close_window, { buffer = buf, nowait = true })

      vim.keymap.set("n", "r", function()
        close_window()
        -- Build conversation context to show while replying
        local context_lines = {
          string.format("# Replying to comment by %s (%s)", comment.user, comment.created_at:sub(1, 10)),
          "",
          "## Original Comment:",
          ""
        }

        -- Add the original comment body with quote markers
        for _, line in ipairs(vim.split(comment.body, "\n")) do
          table.insert(context_lines, "> " .. line)
        end

        table.insert(context_lines, "")
        table.insert(context_lines, "## Your Reply:")
        table.insert(context_lines, "")
        table.insert(context_lines, "")

        local initial_text = table.concat(context_lines, "\n")

        -- Reply to the comment using multiline input with context
        input_multiline("Reply to global comment", function(full_text, restore_draft)
          if not full_text or full_text == "" then
            return
          end

          -- Extract only the reply part (everything after "## Your Reply:")
          local reply_start = full_text:find("## Your Reply:")
          if not reply_start then
            -- Fallback: use the entire text if marker not found
            reply_text = full_text
          else
            -- Find the end of the "## Your Reply:" line
            local reply_line_end = full_text:find("\n", reply_start)
            if reply_line_end then
              reply_text = full_text:sub(reply_line_end + 1):match("^%s*(.-)%s*$") -- trim whitespace
            else
              reply_text = ""
            end
          end

          if reply_text and reply_text ~= "" then
            github.add_pr_comment(pr_number, reply_text, function(ok, add_err)
              if ok then
                vim.notify("✅ Reply added successfully", vim.log.levels.INFO)
              else
                vim.notify("❌ Failed to add reply: " .. (add_err or "unknown"), vim.log.levels.ERROR)
                restore_draft()
              end
            end)
          end
        end, initial_text, {
          pr_number = pr_number,
          file_path = nil,
          line = nil,
          action = "reply_global",
          comment_id = comment.id,
        })
      end, { buffer = buf })

      -- Auto-close if user leaves the buffer (e.g., switches windows)
      vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
          vim.defer_fn(close_window, 10)
        end,
      })
    end)
  end)
end

function M.reply_to_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    vim.notify("No comments on this line", vim.log.levels.WARN)
    return
  end

  local function do_reply(comment)
    -- Check if it's a pending comment
    if comment.is_pending then
      vim.notify("❌ Cannot reply to pending comments. Submit the review first.", vim.log.levels.WARN)
      return
    end

    local file_path = get_relative_path(bufnr)
    input_reply_with_context(comment, comments, function(body, restore_draft)
      if not body then
        return
      end
      vim.notify("Sending reply...", vim.log.levels.INFO)
      github.reply_to_comment(pr_number, comment.id, body, function(ok, err)
        if ok then
          vim.notify("✅ Reply added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to reply: " .. (err or "unknown"), vim.log.levels.ERROR)
          restore_draft()
        end
      end)
    end, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "reply",
      comment_id = comment.id,
    })
  end

  if #line_comments == 1 then
    do_reply(line_comments[1])
  else
    local items = {}
    for _, c in ipairs(line_comments) do
      table.insert(items, string.format("[%s]: %s", c.user, c.body:sub(1, 50)))
    end
    vim.ui.select(items, { prompt = "Select comment to reply:" }, function(_, idx)
      if idx then
        do_reply(line_comments[idx])
      end
    end)
  end
end

function M.edit_my_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user", vim.log.levels.ERROR)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local my_comments = {}
    for _, comment in ipairs(comments) do
      if comment.line == cursor_line and comment.user == current_user then
        table.insert(my_comments, comment)
      end
    end

    if #my_comments == 0 then
      vim.notify("No comments from you on this line", vim.log.levels.WARN)
      return
    end

    local function do_edit(comment)
      -- Show thread first if there are other comments on this line
      local line_comments = {}
      for _, c in ipairs(comments) do
        if c.line == cursor_line then
          table.insert(line_comments, c)
        end
      end

      local function open_edit_buffer()
        local buf = vim.api.nvim_create_buf(false, true)
        local width = math.floor(vim.o.columns * 0.7)
        local height = math.floor(vim.o.lines * 0.6)

        -- Check for existing draft
        local file_path = get_relative_path(bufnr)
        local draft_key = get_draft_key(pr_number, file_path, cursor_line, "edit", comment.id)
        local has_draft = M._drafts[pr_number] and M._drafts[pr_number][draft_key]

        -- Set title based on comment type
        local title = comment.is_pending
            and " Edit PENDING comment (save: <C-s>, cancel: <Esc>) "
            or " Edit comment (save: <C-s>, cancel: <Esc>) "

        if has_draft then
          title = " [DRAFT RESTORED] Edit comment (save: <C-s>, cancel: <Esc>) "
        end

        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = width,
          height = height,
          col = math.floor((vim.o.columns - width) / 2),
          row = math.floor((vim.o.lines - height) / 2),
          style = "minimal",
          border = "rounded",
          title = title,
          title_pos = "center",
        })

        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].bufhidden = "wipe"

        -- Build the thread if there are other comments
        local lines = {}
        if #line_comments > 1 then
          -- Build and show thread
          local thread = build_comment_thread(comment, comments)
          table.insert(lines, "--- Conversation Thread ---")
          table.insert(lines, "")

          for _, item in ipairs(thread) do
            local indent = string.rep("  ", item.depth)
            local prefix = item.depth > 0 and "↳ " or ""

            local date = item.comment.created_at or ""
            if date ~= "" then
              date = " (" .. date:sub(1, 10) .. ")"
            end

            local pending_mark = item.comment.is_pending and " [PENDING]" or ""
            table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. pending_mark .. ":")

            local wrapped = wrap_text(item.comment.body, width - 4, indent)
            for _, wrapped_line in ipairs(wrapped) do
              table.insert(lines, wrapped_line)
            end
            table.insert(lines, "")
          end

          table.insert(lines, "--- Edit your comment below: ---")
          table.insert(lines, "")
        end

        local separator_line = #lines > 0 and (#lines - 1) or 0

        -- Add current comment text (or draft if it exists)
        local text_to_edit = has_draft and has_draft.text or comment.body
        for line in text_to_edit:gmatch("[^\r\n]+") do
          table.insert(lines, line)
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

        -- Highlight separator if thread was shown
        if separator_line > 0 then
          local ns_id = vim.api.nvim_create_namespace("edit_context")
          vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", separator_line - 1, 0, -1)
          vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)
        end

        -- Position cursor at the end of the text
        local last_line = #lines
        vim.api.nvim_win_set_cursor(win, { last_line, 0 })

        vim.keymap.set("n", "<Esc>", function()
          -- Save draft before closing
          local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local text
          if separator_line > 0 then
            local edit_lines = {}
            local found_separator = false
            for i, line in ipairs(new_lines) do
              if line:match("^%-%-%-+ Edit your comment below:") then
                found_separator = true
              elseif found_separator and line ~= "" then
                table.insert(edit_lines, line)
              end
            end
            text = table.concat(edit_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          else
            text = table.concat(new_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          end

          if text ~= "" then
            save_draft(pr_number, file_path, cursor_line, "edit", comment.id, text)
          end

          vim.api.nvim_win_close(win, true)
          vim.cmd("stopinsert")
        end, { buffer = buf })

        vim.keymap.set({ "n", "i" }, "<C-s>", function()
          local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

          -- Extract only the edited text (skip thread if shown)
          local text
          if separator_line > 0 then
            -- Thread was shown, extract only lines after separator
            local edit_lines = {}
            local found_separator = false
            for i, line in ipairs(new_lines) do
              if line:match("^%-%-%-+ Edit your comment below:") then
                found_separator = true
              elseif found_separator and line ~= "" then
                table.insert(edit_lines, line)
              end
            end
            text = table.concat(edit_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          else
            -- No thread, all lines are the comment
            text = table.concat(new_lines, "\n")
          end

          vim.api.nvim_win_close(win, true)
          vim.cmd("stopinsert")
          if text ~= "" then
            -- A comment of the pending review (edited by its GraphQL node id)
            if comment.is_pending then
              vim.notify("Updating pending comment...", vim.log.levels.INFO)
              github.edit_pending_comment(comment.node_id, text, function(ok, edit_err)
                if ok then
                  clear_draft(pr_number, file_path, cursor_line, "edit", comment.id)
                  vim.notify("✅ Pending comment updated", vim.log.levels.INFO)
                  M.load_comments_for_buffer(bufnr, true)
                else
                  vim.notify("❌ Failed to edit: " .. (edit_err or "unknown"), vim.log.levels.ERROR)
                  save_draft(pr_number, file_path, cursor_line, "edit", comment.id, text)
                end
              end)
            else
              -- It's a GitHub comment, use API
              vim.notify("Updating comment...", vim.log.levels.INFO)
              github.edit_comment(pr_number, comment.id, text, function(ok, edit_err)
                if ok then
                  -- Clear draft after successful save
                  clear_draft(pr_number, file_path, cursor_line, "edit", comment.id)

                  vim.notify("✅ Comment updated", vim.log.levels.INFO)
                  M.load_comments_for_buffer(bufnr, true)
                else
                  vim.notify("❌ Failed to edit: " .. (edit_err or "unknown"), vim.log.levels.ERROR)
                  save_draft(pr_number, file_path, cursor_line, "edit", comment.id, text)
                end
              end)
            end
          end
        end, { buffer = buf })

        -- Enter insert mode automatically
        vim.cmd("startinsert!")  -- Append at end of line
      end

      -- Thread is now shown inline in the edit buffer
      open_edit_buffer()
    end

    if #my_comments == 1 then
      do_edit(my_comments[1])
    else
      local items = {}
      for _, c in ipairs(my_comments) do
        table.insert(items, c.body:sub(1, 50))
      end
      vim.ui.select(items, { prompt = "Select comment to edit:" }, function(_, idx)
        if idx then
          do_edit(my_comments[idx])
        end
      end)
    end
  end)
end

function M.delete_my_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user", vim.log.levels.ERROR)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local my_comments = {}
    for _, comment in ipairs(comments) do
      if comment.line == cursor_line and comment.user == current_user then
        table.insert(my_comments, comment)
      end
    end

    if #my_comments == 0 then
      vim.notify("No comments from you on this line", vim.log.levels.WARN)
      return
    end

    local function do_delete(comment)
      vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
        if choice == "Yes" then
          vim.notify("Deleting comment...", vim.log.levels.INFO)

          -- A comment of the pending review (deleted by its GraphQL node id)
          if comment.is_pending then
            github.delete_pending_comment(comment.node_id, function(ok, del_err)
              if ok then
                vim.notify("✅ Pending comment deleted", vim.log.levels.INFO)
                M.load_comments_for_buffer(bufnr, true)
              else
                vim.notify("❌ Failed to delete: " .. (del_err or "unknown"), vim.log.levels.ERROR)
              end
            end)
          else
            -- It's a GitHub comment, use API
            github.delete_comment(pr_number, comment.id, function(ok, del_err)
              if ok then
                vim.notify("✅ Comment deleted", vim.log.levels.INFO)
                M.load_comments_for_buffer(bufnr, true)
              else
                vim.notify("❌ Failed to delete: " .. (del_err or "unknown"), vim.log.levels.ERROR)
              end
            end)
          end
        end
      end)
    end

    if #my_comments == 1 then
      do_delete(my_comments[1])
    else
      local items = {}
      for _, c in ipairs(my_comments) do
        table.insert(items, c.body:sub(1, 50))
      end
      vim.ui.select(items, { prompt = "Select comment to delete:" }, function(_, idx)
        if idx then
          do_delete(my_comments[idx])
        end
      end)
    end
  end)
end

function M.show_session_info()
  local session_data, workspace_pr, session_file = find_session()

  local lines = {
    "Session file: " .. (session_file or "none"),
    "PR checked out in this workspace: " .. (workspace_pr and ("#" .. workspace_pr) or "none"),
    "",
  }

  if session_data then
    table.insert(lines, "Saved session:")
    table.insert(lines, "  PR #" .. (session_data.pr_number or "nil"))
    table.insert(lines, "  Base branch: " .. (session_data.base_branch or "nil"))
    table.insert(lines, "  Mode: " .. (session_data.mode or "nil"))
    table.insert(lines, "  Review root: " .. (session_data.root or "nil"))
    table.insert(lines, "  Merge base: " .. (session_data.merge_base or "nil"))
    table.insert(lines, "  Review change: " .. (session_data.review_change or "nil"))
    table.insert(lines, "  Previous change: " .. vim.inspect(session_data.previous_change))
    table.insert(lines, "  CWD: " .. (session_data.cwd or "nil"))
    table.insert(lines, "  Viewed files: " .. vim.inspect(session_data.viewed_files or {}))
    table.insert(lines, "  Pending comments: " .. #(session_data.pending_comments or {}))
  else
    table.insert(lines, "No saved session found")
  end

  table.insert(lines, "")
  table.insert(lines, "Current state:")
  table.insert(lines, "  vim.g.pr_review_number: " .. vim.inspect(vim.g.pr_review_number))
  table.insert(lines, "  Current CWD: " .. vim.fn.getcwd())
  local current_change = jj.current_change()
  table.insert(lines, "  Current change: " .. (current_change and current_change.change_id or "nil"))

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Restore a saved review session. Returns false if its review change is gone
local function restore_session(session_data)
  if session_data.repo_id and session_data.repo_id ~= jj.repo_id() then
    vim.notify("Session is for a different repository: " .. session_data.repo_id, vim.log.levels.WARN)
    return false
  end

  -- Check that the review change still exists where the session says it is
  local root = session_data.root or vim.fn.getcwd()
  if vim.fn.isdirectory(root) == 0 or not jj.current_review_pr(root) then
    vim.notify("No review change found in " .. root .. ". Use :PR to start a new review.", vim.log.levels.WARN)
    return false
  end

  vim.notify("Restoring review session for PR #" .. session_data.pr_number .. "...", vim.log.levels.INFO)

  -- Restore global state
  vim.g.pr_review_number = session_data.pr_number
  vim.g.pr_review_base_branch = session_data.base_branch
  vim.g.pr_review_previous_change = session_data.previous_change
  set_review_location({
    mode = session_data.mode or "inplace",
    root = root,
    main_root = session_data.main_root,
    workspace = session_data.workspace,
    merge_base = session_data.merge_base,
    head = session_data.head,
    review_change = session_data.review_change,
  })
  if session_data.mode == "workspace" then
    enter_review_workspace(root)
  end
  vim.g.pr_review_modified_files = session_data.modified_files
  M._viewed_files = session_data.viewed_files or {}
  M._viewed_commit_files = session_data.viewed_commit_files or {}
  M._commit_mode = session_data.commit_mode or false
  M._current_commit = session_data.current_commit
  github.comment_commit_id = M._commit_mode and M._current_commit or nil
  -- Older versions kept pending comments in the session: move them to the GitHub pending review
  migrate_local_pending_comments(session_data.pending_comments)
  M._drafts = session_data.drafts or {}

  -- Start polling for remote updates
  start_update_polling()

  -- Open review buffer and first file (the commit list decides the files in commit mode)
  M._commits = nil
  load_commits(function()
    if M._commit_mode and not current_commit() then
      vim.notify("The reviewed commit is no longer part of the PR, use " .. M.config.commit_mode_toggle_key ..
        " to go back to the whole PR", vim.log.levels.WARN)
    end
    M.open_review_buffer(function()
      -- Use the ordered list (same order as ReviewBuffer)
      local first_file = #M._review_files_ordered > 0 and M._review_files_ordered[1] or M._review_files[1]
      if first_file then
        open_file_safe(first_file, nil)
      end
    end)
  end)

  vim.notify("✅ Session restored for PR #" .. session_data.pr_number, vim.log.levels.INFO)
  return true
end

-- A review change without a saved session: start the review of that PR again where it is
-- (a secondary workspace is reused in workspace mode; the default workspace means inplace)
local function resume_without_session(pr_number, root)
  vim.notify("No saved session for PR #" .. pr_number .. ", starting its review...", vim.log.levels.INFO)
  local secondary = root ~= jj.workspaces().default
  if not secondary then
    jj.cwd = root
  end
  github.get_pr_for_review(pr_number, function(pr, err)
    if not pr then
      vim.notify("Error getting PR #" .. pr_number .. ": " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    M._do_start_review(pr, secondary and "workspace" or "inplace")
  end)
end

function M.load_last_session()
  if vim.g.pr_review_number then
    vim.notify("Already in review mode.", vim.log.levels.INFO)
    -- Just open the review buffer
    M.open_review_buffer()
    return
  end

  local session_data, workspace_pr = find_session()
  if session_data then
    restore_session(session_data)
  elseif workspace_pr then
    resume_without_session(workspace_pr, jj.root(vim.fn.getcwd()))
  else
    vim.notify("No saved session found for this project", vim.log.levels.INFO)
  end
end

function M.show_pr_info()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.get_pr_info(pr_number, function(info, err)
    if err then
      vim.notify("Failed to get PR info: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Fetch CI checks in parallel
    github.get_pr_checks(pr_number, function(checks, checks_err)
      -- Continue even if checks fail
      local ci_checks = checks or {}

      local review_status = info.review_decision or "PENDING"
      local review_icon, approved_icon, changes_icon, comment_icon, mergeable_icon
      local author_prefix, branch_prefix, files_prefix, add_prefix, del_prefix
      local check_pass_icon, check_fail_icon, check_pending_icon

      if M.config.show_icons then
        check_pass_icon = "✅"
        check_fail_icon = "❌"
        check_pending_icon = "🔄"
        review_icon = "⏳"
        if review_status == "APPROVED" then
          review_icon = "✅"
        elseif review_status == "CHANGES_REQUESTED" then
          review_icon = "❌"
        elseif review_status == "REVIEW_REQUIRED" then
          review_icon = "👀"
        end

        mergeable_icon = "❓"
        if info.mergeable == "MERGEABLE" then
          mergeable_icon = "✅"
        elseif info.mergeable == "CONFLICTING" then
          mergeable_icon = "⚠️"
        end

        approved_icon = "✅"
        changes_icon = "❌"
        comment_icon = "💬"
        author_prefix = "👤 Author:"
        branch_prefix = "🌿"
        files_prefix = "📁 Files changed:"
        add_prefix = "➕ Additions:"
        del_prefix = "➖ Deletions:"
      else
        check_pass_icon = "[PASS]"
        check_fail_icon = "[FAIL]"
        check_pending_icon = "[...]"
        review_icon = "[PENDING]"
        if review_status == "APPROVED" then
          review_icon = "[APPROVED]"
        elseif review_status == "CHANGES_REQUESTED" then
          review_icon = "[CHANGES]"
        elseif review_status == "REVIEW_REQUIRED" then
          review_icon = "[REVIEW]"
        end

        mergeable_icon = "[?]"
        if info.mergeable == "MERGEABLE" then
          mergeable_icon = "[OK]"
        elseif info.mergeable == "CONFLICTING" then
          mergeable_icon = "[CONFLICT]"
        end

        approved_icon = "[+]"
        changes_icon = "[-]"
        comment_icon = ""
        author_prefix = "Author:"
        branch_prefix = ""
        files_prefix = "Files changed:"
        add_prefix = "Additions:"
        del_prefix = "Deletions:"
      end

      local approved_by = ""
      if info.reviewers and #info.reviewers.approved > 0 then
        approved_by = " (" .. table.concat(info.reviewers.approved, ", ") .. ")"
      end

      local changes_by = ""
      if info.reviewers and #info.reviewers.changes_requested > 0 then
        changes_by = " (" .. table.concat(info.reviewers.changes_requested, ", ") .. ")"
      end

      local lines = {
        string.format("# PR #%d", info.number),
        "",
        string.format("**%s**", info.title),
        "",
        string.format("%s %s", author_prefix, info.author),
        string.format("%s %s → %s", branch_prefix, info.head_branch, info.base_branch),
        "",
      }

      -- Add description if present
      if info.body and info.body ~= "" then
        table.insert(lines, "## Description")
        table.insert(lines, "")
        for body_line in info.body:gmatch("[^\r\n]+") do
          table.insert(lines, body_line)
        end
        table.insert(lines, "")
      end

      -- Add stats
      vim.list_extend(lines, {
        "## Stats",
        string.format("%s %d", files_prefix, info.changed_files),
        string.format("%s %d", add_prefix, info.additions),
        string.format("%s %d", del_prefix, info.deletions),
        "",
        "## Reviews",
        string.format("%s Status: %s", review_icon, review_status:gsub("_", " ")),
        string.format("%s Approved: %d%s", approved_icon, info.reviews.approved, approved_by),
        string.format("%s Changes requested: %d%s", changes_icon, info.reviews.changes_requested, changes_by),
        string.format("%s Commented: %d", comment_icon, info.reviews.commented),
        "",
      })

      -- Prepare for CI checks (declare outside block for keymap access)
      local failed_urls = {}

      -- Add CI checks
      if #ci_checks > 0 then
        table.insert(lines, "## CI Checks")
        local passed = 0
        local failed = 0
        local pending = 0
        local failed_jobs = {}
        local pending_jobs = {}

        for _, check in ipairs(ci_checks) do
          local icon
          local status = check.conclusion or check.state

          if status == "success" or status == "SUCCESS" then
            icon = check_pass_icon
            passed = passed + 1
          elseif status == "failure" or status == "FAILURE" then
            icon = check_fail_icon
            failed = failed + 1
            table.insert(failed_jobs, check.name)
            if check.detailsUrl then
              table.insert(failed_urls, { name = check.name, url = check.detailsUrl })
            end
          else
            icon = check_pending_icon
            pending = pending + 1
            table.insert(pending_jobs, check.name)
          end

          table.insert(lines, string.format("%s %s", icon, check.name))
        end

        table.insert(lines, "")
        local total_jobs = passed + failed + pending
        table.insert(lines, string.format("**Summary:** %d/%d jobs passed", passed, total_jobs))

        if failed > 0 then
          table.insert(lines, string.format("%s **Failed jobs:** %s", check_fail_icon, table.concat(failed_jobs, ", ")))
          -- Add instructions to view details
          if #failed_urls > 0 then
            table.insert(lines, "")
            table.insert(lines, "*Press `o` to open failed check in browser, `y` to copy URL*")
          end
        end

        if pending > 0 then
          table.insert(lines,
            string.format("%s **Pending jobs:** %s", check_pending_icon, table.concat(pending_jobs, ", ")))
        end

        table.insert(lines, "")
      end

      vim.list_extend(lines, {
        "## Status",
        string.format("%s Mergeable: %s", mergeable_icon, info.mergeable or "UNKNOWN"),
        string.format("%s Comments: %d", comment_icon, info.comments_count),
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "markdown"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].modifiable = false

      local width = math.min(100, math.floor(vim.o.columns * 0.8))
      local height = math.min(#lines, math.floor(vim.o.lines * 0.8))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " PR Info ",
        title_pos = "center",
      })

      local function close_window()
        -- Delete buffer first (will auto-close window due to bufhidden=wipe)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        -- Also try to close window if still valid
        pcall(vim.api.nvim_win_close, win, true)
      end

      vim.keymap.set("n", "q", close_window, { buffer = buf, nowait = true })
      vim.keymap.set("n", "<Esc>", close_window, { buffer = buf, nowait = true })

      -- Add keymaps for failed checks interaction
      if #failed_urls > 0 then
        -- 'o' to open first failed check in browser
        vim.keymap.set("n", "o", function()
          if failed_urls[1] then
            local url = failed_urls[1].url
            if vim.fn.has("mac") == 1 then
              vim.fn.jobstart("open " .. vim.fn.shellescape(url), { detach = true })
            elseif vim.fn.has("win32") == 1 then
              vim.fn.jobstart('cmd /c start "" ' .. vim.fn.shellescape(url), { detach = true })
            else
              vim.fn.jobstart("xdg-open " .. vim.fn.shellescape(url), { detach = true })
            end
            vim.notify("Opening: " .. failed_urls[1].name, vim.log.levels.INFO)
          end
        end, { buffer = buf, nowait = true, desc = "Open failed check in browser" })

        -- 'y' to copy first failed check URL
        vim.keymap.set("n", "y", function()
          if failed_urls[1] then
            vim.fn.setreg("+", failed_urls[1].url)
            vim.notify("Copied URL for: " .. failed_urls[1].name, vim.log.levels.INFO)
          end
        end, { buffer = buf, nowait = true, desc = "Copy failed check URL" })
      end

      -- Auto-close if user leaves the buffer (e.g., switches windows)
      vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
          vim.defer_fn(close_window, 10)
        end,
      })
    end) -- End of get_pr_checks callback
  end)   -- End of get_pr_info callback
end

function M.open_pr()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local cmd = string.format("gh pr view %d --web", pr_number)
  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("Failed to open PR in browser", vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

-- Helper function to check if we should cleanup before starting a new review
local function check_and_cleanup_if_needed(callback)
  if vim.g.pr_review_number then
    -- Already in review mode, ask user if they want to cleanup
    vim.ui.select(
      { "Yes, cleanup first", "No, continue without cleanup" },
      {
        prompt = "You are already reviewing PR #" ..
            vim.g.pr_review_number .. ". Do you want to cleanup the current review before starting a new one?",
      },
      function(choice)
        if not choice then
          -- User cancelled
          return
        end

        if choice == "Yes, cleanup first" then
          -- Cleanup and then call the callback
          M.cleanup_review_branch()
          -- Wait a bit for cleanup to complete before starting new review
          vim.defer_fn(callback, 500)
        else
          -- Continue without cleanup
          callback()
        end
      end
    )
  else
    -- Not in review mode, proceed directly
    callback()
  end
end

function M.list_review_requests()
  check_and_cleanup_if_needed(function()
    vim.notify("Fetching review requests...", vim.log.levels.INFO)

    github.list_review_requests(function(prs, err)
      if err then
        vim.notify("Error fetching review requests: " .. err, vim.log.levels.ERROR)
        return
      end

      if not prs or #prs == 0 then
        vim.notify("No review requests found", vim.log.levels.INFO)
        return
      end

      vim.notify("Found " .. #prs .. " review request(s)", vim.log.levels.INFO)

      local function on_select(pr)
        if not pr then
          return
        end
        M._start_review_for_pr(pr)
      end

      ui.select_review_request(prs, M.config.picker, M.config.show_icons, on_select)
    end)
  end)
end

function M._start_review_for_pr(pr)
  -- Check if already in review mode for a different PR
  if vim.g.pr_review_number and vim.g.pr_review_number ~= pr.number then
    vim.notify(string.format("Cleaning up current review (PR #%d) to start PR #%d...",
      vim.g.pr_review_number, pr.number), vim.log.levels.INFO)
    M.cleanup_review_branch()
    -- Wait a bit for cleanup to complete
    vim.defer_fn(function()
      M._start_review_for_pr(pr)
    end, 500)
    return
  end

  vim.notify("Starting review for PR #" .. pr.number .. "...", vim.log.levels.INFO)

  -- For fork PRs, get the correct branch name using gh pr view
  if pr.head_repo_owner then
    debug_log(string.format("Debug: Detected fork PR, owner=%s, getting details...", pr.head_repo_owner))
    github.get_pr_details(pr.number, function(details, err)
      if err or not details then
        vim.notify("Error getting PR details: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
      end

      debug_log(string.format("Debug: Got branch %s, was %s", details.head_branch, pr.head_branch))

      -- Update PR with correct branch from details
      pr.head_branch = details.head_branch
      pr.head_label = details.head_label

      M._do_start_review(pr)
    end)
  else
    debug_log("Debug: Not a fork PR, using branch as-is")
    M._do_start_review(pr)
  end
end

-- mode_override: "workspace" | "inplace" (default: M.config.review_mode)
function M._do_start_review(pr, mode_override)
  local mode = (mode_override or M.config.review_mode) == "inplace" and "inplace" or "workspace"

  -- Inplace: if we are already on a review change (e.g. continuing without cleanup), replace it
  -- Otherwise remember where we were, to go back there on cleanup
  local replace_change = nil
  if mode == "inplace" then
    local current = jj.current_change()
    if jj.current_review_pr() then
      replace_change = current and current.change_id
    else
      vim.g.pr_review_previous_change = current
    end
  end

  local opts = { mode = mode }
  if mode == "workspace" and M.config.workspace_path then
    local main_root = jj.workspaces().default or jj.root()
    opts.path = M.config.workspace_path(main_root, pr.number)
  end

  jj.checkout_pr(pr, replace_change, opts, function(ok, err, state)
    if not ok then
      vim.notify("Error starting review: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end

    vim.g.pr_review_number = pr.number
    vim.g.pr_review_base_branch = pr.base_branch
    state.mode = mode
    set_review_location(state)
    if mode == "workspace" then
      enter_review_workspace(state.root)
    end
    M._commits = nil
    M._commit_mode = false
    M._current_commit = nil
    github.comment_commit_id = nil
    load_commits()

    -- Start polling for remote updates
    start_update_polling()

    vim.notify(
      string.format("✅ Ready to review PR #%s: %s", pr.number, pr.title),
      vim.log.levels.INFO
    )

    jj.changed_files(state.merge_base, function(files)
      if files and #files > 0 then
        vim.g.pr_review_modified_files = vim.tbl_map(function(f)
          return { path = f.path, status = f.status }
        end, files)

        -- Save initial session
        save_session()

        -- Open review buffer and first file
        M.open_review_buffer(function()
          if M.config.open_files_on_review then
            -- Use the ordered list (same order as ReviewBuffer)
            local first_file = #M._review_files_ordered > 0 and M._review_files_ordered[1] or M._review_files[1]
            if first_file then
              open_file_safe(first_file, nil)
            end
          end
        end)
      end
    end)
  end)
end

-- Highlight groups (default = true, so colorschemes and users can override them)
local function define_highlights()
  vim.api.nvim_set_hl(0, "PRReviewSelection", { link = "CursorLine", default = true }) -- sidebar entry under the cursor
  vim.api.nvim_set_hl(0, "PRReviewCurrent", { bold = true, default = true })          -- open file / reviewed commit
  -- jj change ids in the commit sidebar: unique prefix and the rest (jj log colors)
  vim.api.nvim_set_hl(0, "PRReviewChangeIdPrefix", { fg = "magenta", bold = true, ctermfg = "magenta", default = true })
  vim.api.nvim_set_hl(0, "PRReviewChangeIdRest", { link = "Comment", default = true })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("PRReviewHighlights", { clear = true }),
    callback = define_highlights,
  })

  vim.api.nvim_create_user_command("PRReview", function()
    M.review_pr()
  end, { desc = "Select and review a GitHub PR" })

  vim.api.nvim_create_user_command("PRReviewCleanup", function()
    M.cleanup_review_branch()
  end, { desc = "Exit the review and clean up its jj workspace or change" })

  vim.api.nvim_create_user_command("PRInfo", function()
    M.show_pr_info()
  end, { desc = "Show PR information" })

  vim.api.nvim_create_user_command("PRReviewComment", function()
    M.show_comments_at_cursor()
  end, { desc = "Show PR comments at cursor line" })

  vim.api.nvim_create_user_command("PRApprove", function()
    M.approve_pr()
  end, { desc = "Approve the current PR" })

  vim.api.nvim_create_user_command("PRRequestChanges", function()
    M.request_changes()
  end, { desc = "Request changes on the current PR" })

  vim.api.nvim_create_user_command("PRComment", function()
    M.add_comment()
  end, { desc = "Add a general comment to the PR" })

  vim.api.nvim_create_user_command("PRLineComment", function()
    M.add_review_comment()
  end, { desc = "Add a review comment on the current line" })

  vim.api.nvim_create_user_command("PRPendingComment", function()
    M.add_pending_comment()
  end, { desc = "Add a pending review comment (posted with approval/rejection)" })

  vim.api.nvim_create_user_command("PRSubmitPendingComments", function()
    M.submit_pending_comments()
  end, { desc = "Submit your pending review as a comment (without approving or requesting changes)" })

  vim.api.nvim_create_user_command("PRListPendingComments", function()
    M.list_pending_comments()
  end, { desc = "List all pending comments and navigate to selected one" })

  vim.api.nvim_create_user_command("PRListAllComments", function()
    M.list_all_comments()
  end, { desc = "List all comments (pending + posted) with preview" })

  vim.api.nvim_create_user_command("PRGlobalComments", function()
    M.list_global_comments()
  end, { desc = "List and view global PR comments" })

  vim.api.nvim_create_user_command("PRReply", function()
    M.reply_to_comment()
  end, { desc = "Reply to a comment on the current line" })

  vim.api.nvim_create_user_command("PREditComment", function()
    M.edit_my_comment()
  end, { desc = "Edit your comment on the current line" })

  vim.api.nvim_create_user_command("PRDeleteComment", function()
    M.delete_my_comment()
  end, { desc = "Delete your comment on the current line" })

  vim.api.nvim_create_user_command("PRToggleReaction", function()
    M.add_reaction_to_comment()
  end, { desc = "Toggle emoji reaction on a comment at the current line" })

  vim.api.nvim_create_user_command("PRReviewMenu", function()
    M.show_review_menu()
  end, { desc = "Show PR Reviewer command menu" })

  vim.api.nvim_create_user_command("PR", function()
    M.show_review_menu()
  end, { desc = "Show PR Reviewer command menu (alias for PRReviewMenu)" })

  -- Visual mode suggestion command
  -- Recommended keybind: vim.keymap.set('v', '<leader>gs', ':<C-u>\'<,\'>PRSuggestChange<CR>', { desc = 'Suggest change' })
  -- This ensures the range is always passed correctly
  vim.api.nvim_create_user_command("PRSuggestChange", function(args)
    local start_line, end_line

    -- Get visual selection from range if provided (when called with ':<,'>PRSuggestChange')
    if args.range > 0 then
      start_line = args.line1
      end_line = args.line2
    else
      -- Fallback to marks (when called with '<cmd>PRSuggestChange<CR>')
      local start_pos = vim.fn.getpos("'<")
      local end_pos = vim.fn.getpos("'>")

      if start_pos[2] == 0 or end_pos[2] == 0 then
        vim.notify("No visual selection. Select code first with V or v", vim.log.levels.WARN)
        return
      end

      start_line = start_pos[2]
      end_line = end_pos[2]
    end

    -- Get the full lines
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

    if #lines == 0 then
      vim.notify("No lines selected", vim.log.levels.WARN)
      return
    end

    local visual_sel = {
      text = table.concat(lines, "\n"),
      full_lines = lines,
      start_line = start_line,
      end_line = end_line,
    }

    M._visual_selection = visual_sel

    -- Ask which type
    vim.ui.select(
      { "Immediate (post now)", "Pending (post with review)" },
      { prompt = "Suggest code change:" },
      function(choice, idx)
        if not choice then
          M._visual_selection = nil
          return
        end

        if idx == 1 then
          M.add_review_comment_with_selection()
        else
          M.add_pending_comment_with_selection()
        end
      end
    )
  end, { desc = "Suggest code change from visual selection", range = true })

  vim.api.nvim_create_user_command("PRListReviewRequests", function()
    M.list_review_requests()
  end, { desc = "List PRs where you are requested as reviewer" })

  vim.api.nvim_create_user_command("PROpen", function()
    M.open_pr()
  end, { desc = "Open PR in browser" })

  vim.api.nvim_create_user_command("PRReviewSessions", function()
    M.review_sessions()
  end, { desc = "List open reviews (review workspaces) and open or remove one" })

  vim.api.nvim_create_user_command("PRLoadLastSession", function()
    M.load_last_session()
  end, { desc = "Load last PR review session" })

  vim.api.nvim_create_user_command("PRSessionInfo", function()
    M.show_session_info()
  end, { desc = "Show saved session info" })

  vim.api.nvim_create_user_command("PRRefresh", function()
    M.refresh_pr_branch()
  end, { desc = "Refresh PR branch with latest changes" })

  vim.api.nvim_create_user_command("PRReviewBuffer", function()
    M.open_review_buffer()
  end, { desc = "Open PR review buffer" })

  -- Setup global navigation keymaps
  setup_global_review_keymaps()

  local augroup = vim.api.nvim_create_augroup("PRReviewComments", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      if vim.g.pr_review_number then

        M.load_comments_for_buffer(args.buf)

        -- Changed lines (comment validation, first-change jump) and buffer keymaps
        load_changes_for_buffer(args.buf)

        -- Update review buffer to highlight current file
        M.refresh_review_buffer()

        -- Jump to first change if we haven't already for this buffer
        if not M._buffer_jumped[args.buf] then
          vim.defer_fn(function()
            local hunks = M._buffer_hunks[args.buf]
            if hunks and #hunks > 0 and vim.api.nvim_get_current_buf() == args.buf then
              -- Check if the line exists in the buffer before setting cursor
              local line_count = vim.api.nvim_buf_line_count(args.buf)
              if hunks[1].start_line > 0 and hunks[1].start_line <= line_count then
                vim.api.nvim_win_set_cursor(0, { hunks[1].start_line, 0 })
                vim.cmd("normal! zz")
              end
              M._buffer_jumped[args.buf] = true
            end
          end, 100)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorHold", {
    group = augroup,
    callback = function()
      if vim.g.pr_review_number then
        M.show_comments_at_cursor()
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = function()
      if vim.g.pr_review_number then
        update_changes_float()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    callback = function()
      close_float_wins()
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      -- Clean up tracking when buffer is deleted
      M._buffer_keymaps_saved[args.buf] = nil
      M._buffer_jumped[args.buf] = nil
      M._buffer_comments[args.buf] = nil
      M._buffer_changes[args.buf] = nil
      M._buffer_hunks[args.buf] = nil
    end,
  })

  -- Note: Keymaps are now set as buffer-local in the BufEnter autocmd
  -- This ensures they only work during review mode and don't conflict with existing keymaps
end

function M.review_pr()
  check_and_cleanup_if_needed(function()
    local prs, err = github.list_open_prs()
    if err then
      vim.notify("Error fetching PRs: " .. err, vim.log.levels.ERROR)
      return
    end

    if #prs == 0 then
      vim.notify("No open PRs found", vim.log.levels.INFO)
      return
    end

    ui.select_pr(prs, M.config.picker, function(pr)
      if not pr then
        return
      end

      -- For fork PRs, get the correct branch name using gh pr view
      if pr.head_repo_owner then
        debug_log(string.format("Debug: Detected fork PR, owner=%s, getting details...", pr.head_repo_owner))
        github.get_pr_details(pr.number, function(details, err)
          if err or not details then
            vim.notify("Error getting PR details: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
          end

          debug_log(string.format("Debug: Got branch %s, was %s", details.head_branch, pr.head_branch))

          -- Update PR with correct branch from details
          pr.head_branch = details.head_branch
          pr.head_label = details.head_label

          debug_log("Debug: About to call _do_start_review")
          M._do_start_review(pr)
        end)
      else
        debug_log("Debug: Not a fork PR, using branch as-is")
        M._do_start_review(pr)
      end
    end)
  end)
end

-- ===== Commit mode: review the PR one commit at a time =====

-- Take over the viewed state from GitHub: a file viewed there is viewed in every commit that
-- changes it; a file viewed here but not there (unmarked on GitHub, or DISMISSED because it changed
-- since) is unmarked in all of them. Files toggled here since the fetch started are left alone.
local function pull_viewed_from_github()
  local pr_number = vim.g.pr_review_number
  if not M.config.sync_viewed_with_github or not pr_number then
    return
  end
  local started = viewed_sync_seq
  github.fetch_viewed_files(pr_number, function(states, err)
    if vim.g.pr_review_number ~= pr_number then
      return
    end
    if not states then
      vim.notify("Failed to fetch the viewed files from GitHub: " .. (err or "unknown"), vim.log.levels.WARN)
      return
    end
    local changed = false
    for path, state in pairs(states) do
      local viewed = state == "VIEWED"
      if (viewed_pushed_at[pr_number .. ":" .. path] or 0) <= started and viewed ~= (M._viewed_files[path] == true) then
        set_file_viewed(path, viewed, nil, { from_github = true })
        changed = true
      end
    end
    if changed then
      save_session()
      M.refresh_review_buffer()
      update_changes_float()
    end
  end)
end

-- Load the PR's commits (needed for commit mode and per-commit viewed state)
load_commits = function(callback)
  if not vim.g.pr_review_merge_base then
    if callback then callback() end
    return
  end
  if not vim.g.pr_review_head and not M._commit_mode then
    -- Sessions from before commit mode, whose review change was created with `jj new <PR head>`
    local change = jj.current_change()
    vim.g.pr_review_head = change and change.parents[1]
  end

  jj.pr_commits(vim.g.pr_review_merge_base, vim.g.pr_review_head or "@-", function(commits)
    local first_load = vim.tbl_isempty(M._viewed_commit_files)
    M._commits = commits

    -- Files marked viewed before per-commit tracking existed count as viewed in all their commits
    if first_load then
      for path, viewed in pairs(M._viewed_files) do
        if viewed then
          for _, commit in ipairs(commits) do
            if commit_touches(commit, path) then
              M._viewed_commit_files[commit.id] = M._viewed_commit_files[commit.id] or {}
              M._viewed_commit_files[commit.id][path] = true
            end
          end
        end
      end
    end

    local seen = {}
    for _, commit in ipairs(commits) do
      for _, f in ipairs(commit.files) do
        if not seen[f.path] then
          seen[f.path] = true
          sync_pr_viewed(f.path)
        end
      end
    end

    save_session()
    pull_viewed_from_github()
    if callback then callback() end
  end)
end

-- Re-read the review files after the working copy moved (commit switch / back to the PR head)
-- and open target_path if it is part of the new file list
local function reload_review_view(target_path)
  M._buffer_changes = {}
  M._buffer_hunks = {}
  M._buffer_comments = {}
  M._buffer_jumped = {}

  local root = review_root()
  local stale = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match(" %[DELETED%]$") then
        -- Deleted-file buffers show content from the old diff base
        table.insert(stale, buf)
      elseif name:sub(1, #root + 1) == root .. "/" and vim.bo[buf].buftype == "" then
        vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
        if vim.fn.filereadable(name) == 1 then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("silent! edit!")
          end)
        else
          -- The file doesn't exist in this revision
          table.insert(stale, buf)
        end
      end
    end
  end

  M._review_files = {}
  M._review_files_ordered = {}
  M.open_review_buffer(function()
    local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files
    local target = nil
    for _, f in ipairs(file_list) do
      if f.path == target_path then
        target = f
      end
    end
    target = target or file_list[1]

    if target then
      open_file_safe(target, nil)
      -- BufEnter doesn't fire when the target was already the current buffer
      local buf = vim.api.nvim_get_current_buf()
      if target.status ~= "D" then
        M.load_comments_for_buffer(buf)
        load_changes_for_buffer(buf)
      end
    end

    for _, buf in ipairs(stale) do
      if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    M.refresh_review_buffer()
    update_changes_float()
  end)
end

-- Review a single commit of the PR. target_path: file to open if the commit changes it
function M.goto_commit(commit_id, target_path)
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end
  if not M._commits then
    vim.notify("Loading PR commits...", vim.log.levels.INFO)
    load_commits(function()
      if M._commits and #M._commits > 0 then
        M.goto_commit(commit_id, target_path)
      end
    end)
    return
  end
  if M._switching_commit then
    return
  end

  local commit, idx = nil, nil
  for i, c in ipairs(M._commits) do
    if c.id == commit_id then
      commit, idx = c, i
    end
  end
  if not commit then
    vim.notify("Commit is not part of this PR: " .. tostring(commit_id), vim.log.levels.ERROR)
    return
  end

  target_path = target_path or get_relative_path(vim.api.nvim_get_current_buf())
  local description = string.format("%s%d: commit %s %s", jj.review_description_prefix, vim.g.pr_review_number,
    commit.change, commit.subject)

  M._switching_commit = true
  jj.move_review_change(commit.parents, commit.id, description, function(ok, err, change_id)
    M._switching_commit = false
    if not ok then
      vim.notify("Failed to switch to commit " .. commit.change .. ": " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    vim.g.pr_review_change = change_id
    M._commit_mode = true
    M._current_commit = commit.id
    github.comment_commit_id = commit.id
    save_session()
    reload_review_view(target_path)
    vim.notify(string.format("Commit %d/%d: %s %s", idx, #M._commits, commit.change, commit.subject),
      vim.log.levels.INFO)
  end)
end

-- Back to reviewing the whole PR
function M.exit_commit_mode()
  if not M._commit_mode or M._switching_commit then
    return
  end
  local target_path = get_relative_path(vim.api.nvim_get_current_buf())
  local description = string.format("%s%d: PR head -> %s", jj.review_description_prefix, vim.g.pr_review_number,
    vim.g.pr_review_base_branch or "base")

  if not vim.g.pr_review_head then
    vim.notify("PR head unknown, use :PRRefresh to go back to the whole PR", vim.log.levels.ERROR)
    return
  end

  M._switching_commit = true
  jj.move_review_change({ vim.g.pr_review_merge_base }, vim.g.pr_review_head, description,
    function(ok, err, change_id)
      M._switching_commit = false
      if not ok then
        vim.notify("Failed to go back to the PR head: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
      end
      vim.g.pr_review_change = change_id
      M._commit_mode = false
      github.comment_commit_id = nil
      save_session()
      reload_review_view(target_path)
      vim.notify("Reviewing the whole PR", vim.log.levels.INFO)
    end)
end

-- Commit to start commit mode on: the last one reviewed, else the first with unviewed files
local function commit_to_enter()
  for _, commit in ipairs(M._commits) do
    if commit.id == M._current_commit then
      return commit
    end
  end
  for _, commit in ipairs(M._commits) do
    local viewed, total = commit_progress(commit)
    if viewed < total then
      return commit
    end
  end
  return M._commits[1]
end

function M.toggle_commit_mode()
  if not vim.g.pr_review_number then
    return
  end
  if M._commit_mode then
    M.exit_commit_mode()
    return
  end
  if not M._commits then
    load_commits(M.toggle_commit_mode)
    return
  end
  local commit = commit_to_enter()
  if not commit then
    vim.notify("This PR has no commits to review", vim.log.levels.WARN)
    return
  end
  M.goto_commit(commit.id)
end

local function step_commit(delta)
  if not vim.g.pr_review_number then
    return
  end
  if not M._commits then
    load_commits(function()
      step_commit(delta)
    end)
    return
  end
  if #M._commits == 0 then
    vim.notify("This PR has no commits to review", vim.log.levels.WARN)
    return
  end
  local _, idx = current_commit()
  if not idx then
    -- From PR mode: next starts at the first commit, previous at the last one
    idx = delta > 0 and 1 or #M._commits
  else
    idx = idx + delta
  end
  if idx < 1 then
    vim.notify("Already at the first commit", vim.log.levels.INFO)
    return
  elseif idx > #M._commits then
    vim.notify("Already at the last commit", vim.log.levels.INFO)
    return
  end
  M.goto_commit(M._commits[idx].id)
end

function M.next_commit()
  step_commit(1)
end

function M.prev_commit()
  step_commit(-1)
end

-- Refresh the PR branch with latest changes
function M.refresh_pr_branch()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local base_branch = vim.g.pr_review_base_branch
  if not base_branch then
    vim.notify("❌ Base branch not found", vim.log.levels.ERROR)
    return
  end

  vim.notify("Refreshing PR branch...", vim.log.levels.INFO)

  -- Get PR details including fork info
  local cmd = string.format(
    "gh pr view %d --json headRefName,headRepositoryOwner,headRepository,isCrossRepository",
    pr_number
  )
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          vim.notify("❌ Failed to get PR details", vim.log.levels.ERROR)
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, pr_info = pcall(vim.fn.json_decode, json_str)
      if not ok or not pr_info then
        vim.schedule(function()
          vim.notify("❌ Failed to parse PR details", vim.log.levels.ERROR)
        end)
        return
      end

      vim.schedule(function()
        local pr = {
          number = pr_number,
          head_branch = pr_info.headRefName,
          base_branch = base_branch,
        }

        if pr_info.isCrossRepository and pr_info.headRepositoryOwner and pr_info.headRepository then
          pr.head_repo_owner = pr_info.headRepositoryOwner.login
          pr.head_repo_url = string.format("https://github.com/%s/%s.git",
            pr.head_repo_owner, pr_info.headRepository.name)
          pr.head_label = pr.head_repo_owner .. ":" .. pr.head_branch
        end

        -- Fetch and create a fresh review change on the new PR head, abandoning the old one
        local replace_change = vim.g.pr_review_change
        if not replace_change and jj.current_review_pr() then
          local current = jj.current_change()
          replace_change = current and current.change_id
        end
        local mode = vim.g.pr_review_mode or "inplace"
        local opts = { mode = mode, path = vim.g.pr_review_root }
        jj.checkout_pr(pr, replace_change, opts, function(checkout_ok, checkout_err, state)
          if not checkout_ok then
            vim.notify("❌ Failed to refresh PR: " .. (checkout_err or "unknown"), vim.log.levels.ERROR)
            return
          end
          state.mode = mode
          set_review_location(state)
          -- The PR head moved: back to PR mode with a fresh commit list
          M._commits = nil
          M._commit_mode = false
          github.comment_commit_id = nil
          load_commits(M.refresh_review_buffer)

          -- Clear all cached data (comments are re-fetched from GitHub when the buffer is reloaded)
          github.clear_cache()
          M._buffer_changes = {}
          M._buffer_hunks = {}
          M._buffer_comments = {}
          M._buffer_jumped = {}

          -- Re-fetch modified files list
          jj.changed_files(state.merge_base, function(files)
            vim.g.pr_review_modified_files = (files and #files > 0) and vim.tbl_map(function(f)
              return { path = f.path, status = f.status }
            end, files) or {}
            save_session()

            -- Reload current buffer
            vim.cmd("edit!")

            -- Reload review buffer with updated file list
            if M._review_buffer and vim.api.nvim_buf_is_valid(M._review_buffer) then
              M._review_files = {}
              M._review_files_ordered = {}
              M.open_review_buffer()
            end

            vim.notify("✅ PR refreshed successfully!", vim.log.levels.INFO)
          end)
        end)
      end)
    end,
  })
end

-- Forget the loaded review in this Neovim (state, sidebar, floats, comment marks, keymaps);
-- doesn't touch jj or the session file
local function reset_review_state()
  stop_update_polling()
  vim.g.pr_review_number = nil
  vim.g.pr_review_base_branch = nil
  vim.g.pr_review_merge_base = nil
  vim.g.pr_review_change = nil
  vim.g.pr_review_previous_change = nil
  vim.g.pr_review_modified_files = nil
  vim.g.pr_review_mode = nil
  vim.g.pr_review_root = nil
  vim.g.pr_review_main_root = nil
  vim.g.pr_review_workspace = nil
  jj.cwd = nil
  github.clear_cache()
  M._buffer_comments = {}
  M._buffer_changes = {}
  M._buffer_hunks = {}
  M._viewed_files = {}
  M._viewed_commit_files = {}
  M._commits = nil
  M._commit_mode = false
  M._current_commit = nil
  M._expanded_commits = {}
  github.comment_commit_id = nil
  M._buffer_jumped = {}
  M._buffer_keymaps_saved = {}
  M._review_files = {}
  M._review_files_ordered = {}
  M._review_filter = "all"
  if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
    pcall(vim.api.nvim_win_close, M._review_window, true)
  end
  M._review_window = nil
  M._review_buffer = nil
  close_float_wins()

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
      -- Delete buffer-local keymaps
      pcall(vim.keymap.del, "n", M.config.mark_as_viewed_key, { buffer = buf })
      pcall(vim.keymap.del, "n", M.config.toggle_floats_key, { buffer = buf })
    end
  end
end

-- Where the review to clean up lives when no review is loaded in this Neovim (e.g. :PRReviewCleanup
-- right after starting Neovim in a review workspace): from the PR's saved session, else from jj
local function detect_review_location(pr_number)
  local session = read_session(get_session_file(pr_number))
  if session and session.mode then
    return {
      mode = session.mode,
      root = session.root,
      main_root = session.main_root,
      workspace = session.workspace,
      previous = session.previous_change,
    }
  end

  local root = jj.root()
  local workspaces = jj.workspaces()
  for name, ws_root in pairs(workspaces) do
    if name ~= "default" and ws_root == root then
      return { mode = "workspace", root = root, main_root = workspaces.default, workspace = name }
    end
  end
  return { mode = "inplace", root = root, main_root = workspaces.default or root }
end

-- opts.confirmed: the user already agreed to exit (skip the confirmation prompt)
function M.cleanup_review_branch(opts)
  opts = opts or {}
  local pr_number = jj.current_review_pr()
  if not pr_number then
    vim.notify("Not on a review change", vim.log.levels.WARN)
    return
  end

  -- No review loaded: find out where it lives so the workspace (if any) is removed too
  if not vim.g.pr_review_mode then
    local location = detect_review_location(pr_number)
    vim.g.pr_review_number = vim.g.pr_review_number or pr_number
    vim.g.pr_review_mode = location.mode
    vim.g.pr_review_root = location.root
    vim.g.pr_review_main_root = location.main_root
    vim.g.pr_review_workspace = location.workspace
    vim.g.pr_review_previous_change = vim.g.pr_review_previous_change or location.previous
  end

  -- Confirm before exiting review
  if not opts.confirmed then
    local choice = vim.fn.confirm("Exit review and abandon the review change?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
  end

  local current = jj.current_change()
  local cleanup_state = {
    mode = vim.g.pr_review_mode or "inplace",
    review_change = current and current.change_id,
    previous = vim.g.pr_review_previous_change,
    workspace = vim.g.pr_review_workspace,
    main_root = vim.g.pr_review_main_root,
  }

  if cleanup_state.mode == "workspace" then
    -- Leave the workspace before it is deleted: wipe its buffers and :cd back out of it
    local root = vim.g.pr_review_root
    wipe_buffers_under(root, true)
    leave_review_workspace(root, cleanup_state.main_root)
    -- The review workspace is about to be deleted, run jj from the main workspace from now on
    jj.cwd = cleanup_state.main_root
  end

  jj.cleanup_review(cleanup_state, function(ok, err, target)
    if ok then
      delete_session()
      reset_review_state()

      vim.notify("Cleaned up review change, back on: " .. target, vim.log.levels.INFO)
    else
      vim.notify("Error cleaning up: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

-- ===== Open review sessions: every workspace whose working copy is a review change =====

-- Put the loaded review aside without cleaning it up: save its session, :cd out, reset state.
-- Its workspace and review change stay, so it can be opened again later.
function M._unload_review()
  if not vim.g.pr_review_number then
    return
  end
  save_session()
  if vim.g.pr_review_mode == "workspace" then
    wipe_buffers_under(vim.g.pr_review_root, false)
    leave_review_workspace(vim.g.pr_review_root, vim.g.pr_review_main_root)
  end
  reset_review_state()
end

-- Open a review from the sessions list, switching away from the loaded one if needed
function M._open_review_session(entry)
  if vim.g.pr_review_number == entry.pr then
    if vim.g.pr_review_mode == "workspace" and vim.g.pr_review_root then
      enter_review_workspace(vim.g.pr_review_root)
    end
    M.open_review_buffer()
    return
  end
  M._unload_review()

  local session_data = read_pr_session(entry.pr)
  if session_data then
    session_data.root = entry.root
    restore_session(session_data)
  else
    resume_without_session(entry.pr, entry.root)
  end
end

-- Remove a review from the sessions list: its workspace (or inplace review change) and session
function M._remove_review_session(entry, done)
  if vim.g.pr_review_number == entry.pr then
    M.cleanup_review_branch()
    return
  end
  local choice = vim.fn.confirm(string.format("Remove the review of PR #%d (%s)?", entry.pr,
    vim.fn.fnamemodify(entry.root, ":~")), "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end

  local workspaces = jj.workspaces()
  local secondary = entry.name ~= "default"
  local session_data = read_pr_session(entry.pr)
  local change = jj.current_change(entry.root)
  if secondary then
    wipe_buffers_under(entry.root, true)
  end
  jj.cleanup_review({
    mode = secondary and "workspace" or "inplace",
    review_change = change and change.change_id,
    workspace = secondary and entry.name or nil,
    main_root = secondary and workspaces.default or entry.root,
    previous = session_data and session_data.previous_change,
  }, function(ok, err)
    if ok then
      vim.fn.delete(get_session_file(entry.pr))
      vim.notify("Removed the review of PR #" .. entry.pr, vim.log.levels.INFO)
    else
      vim.notify("Error removing the review of PR #" .. entry.pr .. ": " .. (err or "unknown"), vim.log.levels.ERROR)
    end
    if done then
      done()
    end
  end)
end

-- ===== Entry points for the bin/prr script =====

local function review_entry_for(pr_number)
  for _, entry in ipairs(jj.review_workspaces()) do
    if entry.pr == pr_number then
      return entry
    end
  end
  return nil
end

-- Headless: make sure PR pr_number has a review workspace (fetch, create it, save its session),
-- write its root to stdout and quit. Exits with code 1 (error on stderr) on failure.
-- Inplace mode creates nothing: the repo root is printed and open_pr() starts the review.
-- `prr context`: everything an agent needs to join a review, as JSON on stdout (headless only).
-- Run in a review workspace (the PR is read from its review change) or pass pr_number. Read-only:
-- GitHub reads plus the session file and `jj log --ignore-working-copy`.
function M.dump_context(pr_number)
  local function finish(data, err)
    if data then
      io.stdout:write(vim.json.encode(data) .. "\n")
      vim.cmd("qa!")
    else
      io.stderr:write((err or "unknown error") .. "\n")
      vim.cmd("cquit! 1")
    end
  end

  local root = jj.root(vim.fn.getcwd())
  if not root then
    return finish(nil, "Not in a jj repository")
  end
  jj.cwd = root
  local change = jj.current_change(root)
  pr_number = tonumber(pr_number) or jj.current_review_pr(root)
  if not pr_number then
    return finish(nil, "Not a review workspace (no 'pr-review #<N>' change at @): pass the PR number")
  end

  local session = read_session(get_session_file(pr_number)) or {}
  local function value(v)
    return v ~= vim.NIL and v or nil
  end

  local results = {}
  local remaining = 7
  local function assemble()
    -- Pending review comments may also be in the posted comment list: keep them once, as pending
    local pending_ids = {}
    for _, c in ipairs(results.pending or {}) do
      pending_ids[c.id] = true
    end
    local threads, by_id = {}, {}
    for _, c in ipairs(results.comments or {}) do
      if not pending_ids[c.id] then
        local entry = {
          id = c.id,
          user = c.user,
          body = c.body,
          created_at = c.created_at,
          reactions = #(c.reactions or {}) > 0 and vim.tbl_map(function(r)
            return r.content .. " by " .. r.user
          end, c.reactions) or nil,
        }
        local parent = by_id[value(c.in_reply_to_id)]
        if parent then
          table.insert(parent.replies, entry)
        else
          entry.path = c.path
          entry.line = value(c.line)
          entry.original_line = value(c.original_line)
          entry.original_commit = value(c.original_commit_id)
          entry.outdated = value(c.line) == nil or nil
          entry.replies = {}
          by_id[c.id] = entry
          table.insert(threads, entry)
        end
      end
    end

    local drafts = {}
    for _, d in pairs((session.drafts or {})[tostring(pr_number)] or (session.drafts or {})[pr_number] or {}) do
      table.insert(drafts, { path = value(d.file_path), line = value(d.line), action = d.action,
        comment_id = value(d.comment_id), text = d.text })
    end

    local pr_head = results.pr and results.pr.headRefOid
    finish({
      viewer = results.viewer,
      pr = results.pr,
      review = {
        root = root,
        change = change and { change_id = change.change_id, parents = change.parents,
          description = vim.trim(change.description) } or nil,
        mode = session.mode,
        merge_base = session.merge_base,
        head = session.head,
        commit_mode = session.commit_mode or false,
        current_commit = session.commit_mode and session.current_commit or nil,
        session_saved = session.pr_number ~= nil,
        -- The PR moved on GitHub since the review change was made (refresh with :PRRefresh)
        stale = (session.head and pr_head and session.head ~= pr_head) or false,
      },
      commits = results.commits,
      files = session.modified_files,
      viewed = {
        github = results.viewed,
        per_commit = session.viewed_commit_files,
      },
      threads = threads,
      pending_review = vim.tbl_map(function(c)
        return { id = c.id, path = c.path, line = c.line, start_line = c.start_line, body = c.body,
          outdated = c.line == nil or nil }
      end, results.pending or {}),
      conversation = results.conversation,
      drafts = #drafts > 0 and drafts or nil,
      errors = results.errors,
    })
  end
  local function done(key, data, err)
    results[key] = data
    if err then
      results.errors = results.errors or {}
      results.errors[key] = err
    end
    remaining = remaining - 1
    if remaining == 0 then
      assemble()
    end
  end

  vim.system({ "gh", "pr", "view", tostring(pr_number), "--json",
    "number,url,title,body,author,state,isDraft,headRefName,baseRefName,headRefOid,reviewDecision,additions,deletions,changedFiles" },
    { text = true, cwd = root }, function(result)
      vim.schedule(function()
        local ok, pr = pcall(vim.json.decode, result.stdout or "")
        done("pr", ok and pr or nil, result.code ~= 0 and vim.trim(result.stderr or "") or nil)
      end)
    end)
  github.fetch_pr_comments(pr_number, function(comments, err)
    done("comments", comments, err)
  end)
  github.get_current_user(function(login, err)
    done("viewer", login, err)
  end)
  github.get_pending_review_comments(pr_number, function(comments, err)
    done("pending", comments, err)
  end)
  github.fetch_pr_global_comments(pr_number, function(comments, err)
    done("conversation", comments, err)
  end)
  github.fetch_viewed_files(pr_number, function(states, err)
    done("viewed", states, err)
  end)
  if session.merge_base and session.head then
    jj.pr_commits(session.merge_base, session.head, function(commits)
      done("commits", vim.tbl_map(function(c)
        return { commit = c.id, change = c.change, subject = c.subject, is_merge = c.is_merge or nil,
          files = vim.tbl_map(function(f)
            return f.status .. " " .. f.path
          end, c.files or {}) }
      end, commits or {}))
    end)
  else
    done("commits", nil)
  end
end

function M.prepare_pr(pr_number)
  pr_number = tonumber(pr_number)
  local function finish(root, err)
    if root then
      io.stdout:write(root .. "\n")
      vim.cmd("qa!")
    else
      io.stderr:write((err or "unknown error") .. "\n")
      vim.cmd("cquit! 1")
    end
  end

  if not pr_number then
    return finish(nil, "prepare_pr: invalid PR number")
  end
  local entry = review_entry_for(pr_number)
  if entry then
    return finish(entry.root)
  end
  local main_root = jj.workspaces().default or jj.root()
  if not main_root then
    return finish(nil, "Not in a jj repository")
  end
  jj.cwd = main_root
  if M.config.review_mode == "inplace" then
    return finish(main_root)
  end

  github.get_pr_for_review(pr_number, function(pr, err)
    if not pr then
      return finish(nil, "Error getting PR #" .. pr_number .. ": " .. (err or "unknown"))
    end
    local opts = { mode = "workspace" }
    if M.config.workspace_path then
      opts.path = M.config.workspace_path(main_root, pr.number)
    end
    jj.checkout_pr(pr, nil, opts, function(ok, checkout_err, state)
      if not ok then
        return finish(nil, "Error starting review: " .. (checkout_err or "unknown"))
      end
      vim.g.pr_review_number = pr.number
      vim.g.pr_review_base_branch = pr.base_branch
      state.mode = "workspace"
      set_review_location(state)
      jj.changed_files(state.merge_base, function(files)
        vim.g.pr_review_modified_files = vim.tbl_map(function(f)
          return { path = f.path, status = f.status }
        end, files or {})
        save_session()
        finish(state.root)
      end)
    end)
  end)
end

-- Open the review of PR pr_number: its saved session / review workspace if there is one,
-- else start a new review (inplace mode, or a workspace that prepare_pr didn't create)
function M.open_pr(pr_number)
  pr_number = tonumber(pr_number)
  local entry = pr_number and review_entry_for(pr_number)
  if entry then
    M._open_review_session(entry)
    return
  end
  github.get_pr_for_review(pr_number, function(pr, err)
    if not pr then
      vim.notify("Error getting PR #" .. tostring(pr_number) .. ": " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    M._do_start_review(pr)
  end)
end

-- Headless: remove every review workspace of this repository (workspace + its directory, review
-- change, saved session), report each on stdout and quit (exit code 1 if any removal failed).
-- An inplace review (in the default workspace) is left alone.
function M.cleanup_reviews()
  local main_root = jj.workspaces().default or jj.root()
  if not main_root then
    io.stderr:write("Not in a jj repository\n")
    vim.cmd("cquit! 1")
    return
  end
  jj.cwd = main_root
  local entries = vim.tbl_filter(function(entry)
    return entry.name ~= "default"
  end, jj.review_workspaces())

  local failed = false
  local function step(i)
    local entry = entries[i]
    if not entry then
      vim.cmd(failed and "cquit! 1" or "qa!")
      return
    end
    jj.cleanup_review({
      mode = "workspace",
      workspace = entry.name,
      review_change = entry.change_id,
      main_root = main_root,
    }, function(ok, err)
      if ok then
        vim.fn.delete(get_session_file(entry.pr))
        io.stdout:write(string.format("Removed the review of PR #%d (%s)\n", entry.pr, entry.root))
      else
        failed = true
        io.stderr:write(string.format("Failed to remove the review of PR #%d (%s): %s\n", entry.pr, entry.root,
          err or "unknown"))
      end
      vim.schedule(function()
        step(i + 1)
      end)
    end)
  end
  step(1)
end

-- List the open reviews of this repository and open (or remove) one
function M.review_sessions()
  local entries = jj.review_workspaces()
  if #entries == 0 then
    vim.notify("No open reviews in this repository", vim.log.levels.INFO)
    return
  end

  local here = jj.root(vim.fn.getcwd())
  for _, entry in ipairs(entries) do
    entry.has_session = read_pr_session(entry.pr) ~= nil
    entry.is_here = entry.root == here
    entry.is_loaded = vim.g.pr_review_number == entry.pr
  end
  -- The review of the current workspace first, then by PR number
  table.sort(entries, function(a, b)
    if a.is_here ~= b.is_here then
      return a.is_here
    end
    return a.pr < b.pr
  end)

  if #entries == 1 and not vim.g.pr_review_number then
    M._open_review_session(entries[1])
    return
  end

  ui.select_review_session(entries, M.config.picker, M._open_review_session, {
    delete_key = M.config.review_sessions_delete_key,
    on_delete = function(entry)
      M._remove_review_session(entry, function()
        vim.schedule(M.review_sessions)
      end)
    end,
  })
end

-- Menu buffer state
M._menu_buffer = nil
M._menu_window = nil
M._visual_selection = nil -- Store visual selection for comments

-- Helper function to get visual selection
local function get_visual_selection()
  -- Use marks to get the last visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end

  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local start_col = start_pos[3]
  local end_col = end_pos[3]

  -- Get the full lines (for suggestion feature, we want complete lines)
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  if #lines == 0 then
    return nil
  end

  return {
    text = table.concat(lines, "\n"),
    full_lines = lines,
    start_line = start_line,
    end_line = end_line,
  }
end

-- Helper function to show menu window
local function show_menu_window(sections)
  -- Create new buffer every time to refresh content
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "pr-review-menu"
  vim.bo[bufnr].modifiable = false

  -- Build menu content
  local lines = {}
  local highlights = {}
  local width = 40

  -- Add sections
  for _, section in ipairs(sections) do
    -- Section title (centered)
    local title_idx = #lines
    local padding = math.floor((width - #section.title) / 2)
    local centered_title = string.rep(" ", padding) .. section.title
    table.insert(lines, centered_title)
    table.insert(highlights, { line = title_idx, col_start = 0, col_end = -1, hl_group = "Title" })

    -- Section items
    for _, item in ipairs(section.items) do
      local line_idx = #lines
      local line = "  " .. item.key .. " - " .. item.desc
      table.insert(lines, line)

      -- Highlight the key (single letter)
      table.insert(highlights, { line = line_idx, col_start = 2, col_end = 3, hl_group = "Keyword" })
    end

    table.insert(lines, "")
  end

  -- Set buffer content (temporarily enable modifiable)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights
  local menu_ns = vim.api.nvim_create_namespace("pr_review_menu")
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, menu_ns, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end

  -- Create floating window
  local height = #lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win_id = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  -- Disable cursor line and modifications
  vim.wo[win_id].cursorline = false
  vim.wo[win_id].number = false
  vim.wo[win_id].relativenumber = false
  vim.wo[win_id].signcolumn = "no"

  -- Save original cursor highlights and make cursor invisible
  local original_cursor = vim.api.nvim_get_hl(0, { name = "Cursor" })
  local original_lcursor = vim.api.nvim_get_hl(0, { name = "lCursor" })
  local original_termcursor = vim.api.nvim_get_hl(0, { name = "TermCursor" })

  -- Preserve original colors and add blend=100 to make cursor invisible
  local cursor_invisible = vim.tbl_extend("force", original_cursor, { blend = 100 })
  local lcursor_invisible = vim.tbl_extend("force", original_lcursor, { blend = 100 })
  local termcursor_invisible = vim.tbl_extend("force", original_termcursor, { blend = 100 })

  vim.api.nvim_set_hl(0, "Cursor", cursor_invisible)
  vim.api.nvim_set_hl(0, "lCursor", lcursor_invisible)
  vim.api.nvim_set_hl(0, "TermCursor", termcursor_invisible)

  -- Function to restore cursor highlights
  local function restore_cursor()
    vim.api.nvim_set_hl(0, "Cursor", original_cursor)
    vim.api.nvim_set_hl(0, "lCursor", original_lcursor)
    vim.api.nvim_set_hl(0, "TermCursor", original_termcursor)
  end

  -- Setup keymaps for the menu buffer
  local function close_menu()
    restore_cursor()
    if vim.api.nvim_win_is_valid(win_id) then
      vim.api.nvim_win_close(win_id, true)
    end
  end

  -- Add autocmds to restore cursor when leaving the menu
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = bufnr,
    once = false,
    callback = restore_cursor,
  })

  -- Close with q and Esc
  vim.keymap.set("n", "q", close_menu, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close_menu, { buffer = bufnr, silent = true, nowait = true })

  -- Setup keymaps for all menu items
  for _, section in ipairs(sections) do
    for _, item in ipairs(section.items) do
      vim.keymap.set("n", item.key, function()
        close_menu()
        -- Execute command after a small delay to allow menu to close
        vim.defer_fn(item.cmd, 50)
      end, { buffer = bufnr, silent = true, nowait = true })
    end
  end
end

function M.show_review_menu()
  -- Check if in review mode
  local in_review_mode = vim.g.pr_review_number ~= nil

  -- Check if there's a saved session
  local open_reviews = in_review_mode and {} or jj.review_workspaces()
  local has_session = #open_reviews > 0

  -- Define menu sections based on mode
  local sections = {}

  if not in_review_mode then
    -- Not in review mode - show PR selection options
    local items = {}

    local review_requests = { key = "r", desc = "List Review Requests", cmd = function() M.list_review_requests() end }

    -- If has session, make Load the primary option (l key); review requests always come second
    if has_session then
      local sessions_desc = #open_reviews == 1 and ("Resume PR #" .. open_reviews[1].pr)
          or string.format("Review Sessions (%d)", #open_reviews)
      table.insert(items, { key = "l", desc = sessions_desc, cmd = function() M.review_sessions() end })
      table.insert(items, review_requests)
      table.insert(items, { key = "p", desc = "List Pull Requests",             cmd = function() M.review_pr() end })
    else
      table.insert(items, { key = "l", desc = "List Pull Requests",             cmd = function() M.review_pr() end })
      table.insert(items, review_requests)
    end

    sections = {
      {
        title = "Pull Request",
        items = items,
      },
    }
  else
    -- In review mode - show review actions
    sections = {
      {
        title = "Pull Request",
        items = {
          { key = "i", desc = "PR Info",            cmd = function() M.show_pr_info() end },
          { key = "o", desc = "Open PR in Browser", cmd = function() M.open_pr() end },
          { key = "c", desc = "Comment on PR",      cmd = function() M.add_comment() end },
          { key = "a", desc = "Approve PR",         cmd = function() M.approve_pr() end },
          { key = "x", desc = "Request Changes",    cmd = function() M.request_changes() end },
          -- Same as commit_mode_toggle_key: whole PR <-> one commit at a time
          { key = "t", desc = M._commit_mode and "Review Whole PR" or "Review by Commit",
            cmd = function() M.toggle_commit_mode() end },
          { key = "e", desc = "Exit Review",        cmd = function() M.cleanup_review_branch() end },
        }
      },
      {
        title = "General",
        items = {
          { key = "b", desc = "Toggle Review Buffer", cmd = function() M.toggle_review_buffer() end },
          { key = "f", desc = "Refresh PR Branch",    cmd = function() M.refresh_pr_branch() end },
          { key = "w", desc = "Review Sessions",      cmd = function() M.review_sessions() end },
        }
      },
      {
        title = "Line Comment",
        items = {
          { key = "l", desc = "Add Line Comment",    cmd = function() M.add_review_comment() end },
          { key = "p", desc = "Add Pending Comment", cmd = function() M.add_pending_comment() end },
          { key = "r", desc = "Reply to Comment",    cmd = function() M.reply_to_comment() end },
          { key = "m", desc = "Edit My Comment",     cmd = function() M.edit_my_comment() end },
          { key = "d", desc = "Delete Comment",      cmd = function() M.delete_my_comment() end },
          { key = "R", desc = "Toggle Reaction",     cmd = function() M.add_reaction_to_comment() end },
        }
      },
      {
        title = "Comments",
        items = {
          { key = "s", desc = "Submit Review (Comment)", cmd = function() M.submit_pending_comments() end },
          { key = "v", desc = "List All Comments",       cmd = function() M.list_all_comments() end },
          { key = "g", desc = "Global PR Comments",      cmd = function() M.list_global_comments() end },
        }
      },
    }
  end

  show_menu_window(sections)
end

return M
