-- Jujutsu (jj) integration.
--
-- A review is a jj change on top of the PR head, described as
-- "pr-review #<number>: <head> -> <base>". In "workspace" mode it lives in its own
-- jj workspace (a sibling directory named <repo>-pr-<number>), in "inplace" mode it is
-- created with `jj new` in the current workspace. Either way the working copy is exactly
-- the PR head, and all diffs are computed against the merge-base of the PR head and the
-- base branch (the same base GitHub uses for the "Files changed" tab).
local M = {}

M.review_description_prefix = "pr-review #"

-- Directory jj commands run in: the review root while a review is active,
-- nil means Neovim's current directory
M.cwd = nil

-- Debug logging helper
local function debug_log(msg)
  local pr_reviewer = require("github-pr-reviewer")
  if pr_reviewer.config.debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

local function jj_cmd(args)
  return vim.list_extend({ "jj", "--no-pager", "--color=never" }, args)
end

-- Run jj synchronously, returns ok, stdout, stderr
local function run(args, cwd)
  local result = vim.system(jj_cmd(args), { text = true, cwd = cwd or M.cwd }):wait()
  return result.code == 0, result.stdout or "", result.stderr or ""
end

-- Run jj asynchronously, callback(ok, stdout, stderr) is called on the main loop
local function run_async(args, callback, cwd)
  debug_log("Debug: jj " .. table.concat(args, " "))
  vim.system(jj_cmd(args), { text = true, cwd = cwd or M.cwd }, function(result)
    vim.schedule(function()
      callback(result.code == 0, result.stdout or "", vim.trim(result.stderr or ""))
    end)
  end)
end

-- Run a list of jj commands one after another, stopping at the first failure
local function run_sequence(commands, callback, cwd)
  local i = 0
  local function step()
    i = i + 1
    if i > #commands then
      callback(true, nil)
      return
    end
    run_async(commands[i], function(ok, _, stderr)
      if ok then
        step()
      else
        callback(false, stderr)
      end
    end, cwd)
  end
  step()
end

local function quote(s)
  return '"' .. (s:gsub('[\\"]', "\\%0")) .. '"'
end

local function remote_bookmark(name, remote)
  return string.format("remote_bookmarks(exact:%s, exact:%s)", quote(name), quote(remote))
end

local function fileset(path)
  return "root-file:" .. quote(path)
end

-- Resolve a revset to a single commit id
local function resolve(revset, cwd)
  local ok, out = run({ "log", "--ignore-working-copy", "--no-graph", "--limit", "1", "-r", revset, "-T", 'commit_id ++ "\\n"' }, cwd)
  if not ok then
    return nil
  end
  local id = vim.trim(out)
  return id ~= "" and id or nil
end

local function exists(change_id, cwd)
  return change_id and resolve(string.format("present(%s)", change_id), cwd) ~= nil
end

-- Root of the workspace jj runs in (the review root during a review)
function M.root(cwd)
  local ok, out = run({ "root", "--ignore-working-copy" }, cwd)
  return ok and vim.trim(out) or nil
end

-- Identifies the repository regardless of which workspace we are in:
-- the resolved path of the shared repo store
function M.repo_id(root)
  root = root or M.root()
  if not root then
    return nil
  end
  local repo = root .. "/.jj/repo"
  if vim.fn.isdirectory(repo) == 0 then
    -- Secondary workspace: .jj/repo is a file with a path relative to .jj/
    local f = io.open(repo, "r")
    if not f then
      return nil
    end
    local target = vim.trim(f:read("*a"))
    f:close()
    repo = target:sub(1, 1) == "/" and target or (root .. "/.jj/" .. target)
  end
  return (vim.fn.resolve(vim.fn.fnamemodify(repo, ":p")):gsub("/$", ""))
end

-- Info about the working-copy change: { change_id, description, parents }
function M.current_change(cwd)
  local template = 'change_id ++ "\\n" ++ parents.map(|c| c.commit_id()).join(" ") ++ "\\n" ++ description'
  local ok, out = run({ "log", "--no-graph", "-r", "@", "-T", template }, cwd)
  if not ok then
    return nil
  end
  local change_id, parents, description = out:match("^([^\n]*)\n([^\n]*)\n?(.*)$")
  if not change_id then
    return nil
  end
  return {
    change_id = change_id,
    parents = vim.split(parents, " ", { trimempty = true }),
    description = description,
  }
end

-- Returns the PR number if the working copy is a review change
function M.current_review_pr(cwd)
  local change = M.current_change(cwd)
  if not change then
    return nil
  end
  local prefix = vim.pesc(M.review_description_prefix)
  local number = change.description:match("^" .. prefix .. "(%d+)")
  return number and tonumber(number) or nil
end

-- Returns the remote that holds the PR head branch, adding a remote for forks
local function ensure_head_remote(head_repo_owner, head_repo_url)
  if not head_repo_owner or not head_repo_url then
    return "origin"
  end

  local remote_name = "fork-" .. head_repo_owner
  local ok, out = run({ "git", "remote", "list" })
  if ok then
    for line in out:gmatch("[^\n]+") do
      if line:match("^(%S+)") == remote_name then
        return remote_name
      end
    end
  end

  if run({ "git", "remote", "add", remote_name, head_repo_url }) then
    return remote_name
  end
  return "origin"
end

-- Workspace name -> absolute root, for all workspaces of the repo
function M.workspaces()
  local ok, out = run({ "workspace", "list", "--ignore-working-copy", "-T", 'name ++ "\\t" ++ root ++ "\\n"' })
  local result = {}
  if ok then
    for line in out:gmatch("[^\n]+") do
      local name, root = line:match("^([^\t]+)\t(.*)$")
      if name then
        result[name] = root
      end
    end
  end
  return result
end

-- Default location of a review workspace: <repo-root>/../<repo-name>-pr-<number>
function M.default_workspace_path(repo_root, pr_number)
  return string.format("%s/%s-pr-%d", vim.fn.fnamemodify(repo_root, ":h"), vim.fn.fnamemodify(repo_root, ":t"), pr_number)
end

-- Fetch the PR, create a review change on top of its head and compute the merge-base.
-- pr: { number, head_branch, base_branch, head_repo_owner?, head_repo_url? }
-- opts: { mode = "workspace"|"inplace", path? } (path: where to create the review workspace)
-- callback(ok, err, { merge_base, head, review_change, root, main_root, workspace? })
-- inplace: if replace_change is given (refresh), that review change is abandoned afterwards.
-- workspace: an existing pr-<number> workspace is reused and its previous change abandoned.
function M.checkout_pr(pr, replace_change, opts, callback)
  local head_remote = ensure_head_remote(pr.head_repo_owner, pr.head_repo_url)

  local fetches = { { "git", "fetch", "--remote", "origin", "--branch", "exact:" .. pr.base_branch } }
  if head_remote == "origin" then
    vim.list_extend(fetches[1], { "--branch", "exact:" .. pr.head_branch })
  else
    table.insert(fetches, { "git", "fetch", "--remote", head_remote, "--branch", "exact:" .. pr.head_branch })
  end

  run_sequence(fetches, function(fetch_ok, fetch_err)
    if not fetch_ok then
      callback(false, "jj git fetch failed: " .. (fetch_err or "unknown"))
      return
    end

    local head = resolve(remote_bookmark(pr.head_branch, head_remote))
    local base = resolve(remote_bookmark(pr.base_branch, "origin"))
    if not head or not base then
      callback(false, string.format("Could not find %s@%s or %s@origin", pr.head_branch, head_remote, pr.base_branch))
      return
    end
    local merge_base = resolve(string.format("heads(::%s & ::%s)", head, base))
    debug_log(string.format("Debug: head=%s base=%s merge_base=%s", head, base, merge_base or "nil"))

    local description = string.format("%s%d: %s -> %s", M.review_description_prefix, pr.number,
      pr.head_label or pr.head_branch, pr.base_branch)
    merge_base = merge_base or base
    -- The review change sits on the merge-base with the PR head's content restored into it, so git
    -- (HEAD = merge-base in a colocated workspace) shows the PR's changes too: gitsigns, fugitive, git diff
    local restore_head = { "restore", "--from", head }

    local workspaces = M.workspaces()
    local main_root = workspaces.default or M.root()
    local name = "pr-" .. pr.number
    local root, commands = main_root, nil

    if opts.mode == "workspace" then
      root = workspaces[name]
      if root and vim.fn.isdirectory(root) == 1 then
        -- Reuse the existing review workspace (refresh, or a review that was never cleaned up),
        -- replacing its previous review change
        run({ "workspace", "update-stale" }, root)
        local previous = M.current_review_pr(root) and M.current_change(root)
        replace_change = previous and previous.change_id or nil
        commands = { { "new", merge_base, "-m", description }, restore_head }
      else
        if root then
          run({ "workspace", "forget", name })
        end
        root = opts.path or M.default_workspace_path(main_root, pr.number)
        commands = { { "workspace", "add", "--name", name, "-r", merge_base, "-m", description, root } }
        -- `workspace add` must run from an existing workspace
        run_sequence(commands, function(ok, err)
          if not ok then
            callback(false, "Failed to create review workspace: " .. (err or "unknown"))
            return
          end
          if not run(restore_head, root) then
            callback(false, "Failed to restore the PR head into the review workspace")
            return
          end
          local change = M.current_change(root)
          callback(true, nil, {
            merge_base = merge_base,
            head = head,
            review_change = change and change.change_id,
            root = root,
            main_root = main_root,
            workspace = name,
          })
        end, main_root)
        return
      end
    else
      commands = { { "new", merge_base, "-m", description }, restore_head }
    end

    if replace_change and exists(replace_change, root) then
      table.insert(commands, { "abandon", replace_change })
    end

    run_sequence(commands, function(ok, err)
      if not ok then
        callback(false, "Failed to create review change: " .. (err or "unknown"))
        return
      end
      local change = M.current_change(root)
      callback(true, nil, {
        merge_base = merge_base,
        head = head,
        review_change = change and change.change_id,
        root = root,
        main_root = main_root,
        workspace = opts.mode == "workspace" and name or nil,
      })
    end, root)
  end)
end

local diff_entry_template = 'self.status() ++ "\\t" ++ self.source().path() ++ "\\t" ++ self.target().path() ++ "\\n"'

-- Parse `jj diff -T diff_entry_template` output into { { path, status = "A"|"M"|"D" } }
local function parse_diff_entries(out)
  local files = {}
  for line in out:gmatch("[^\n]+") do
    local status, source, target = line:match("^(%S+)\t([^\t]*)\t(.*)$")
    if status == "added" or status == "copied" then
      table.insert(files, { path = target, status = "A" })
    elseif status == "removed" then
      table.insert(files, { path = source, status = "D" })
    elseif status == "renamed" then
      table.insert(files, { path = source, status = "D" })
      table.insert(files, { path = target, status = "A" })
    elseif status then
      table.insert(files, { path = target, status = "M" })
    end
  end
  return files
end

-- List files changed between the merge-base and the working copy.
-- callback(files) with files = { { path, status = "A"|"M"|"D" } }
function M.changed_files(merge_base, callback)
  run_async({ "diff", "--from", merge_base or "trunk()", "--to", "@", "-T", diff_entry_template }, function(ok, out)
    local files = ok and parse_diff_entries(out) or {}
    debug_log(string.format("Debug: Found %d changed files", #files))
    callback(files)
  end)
end

-- The PR's commits, oldest first, each with the files it changes.
-- Merge commits are diffed against their auto-merged parents (as `jj diff -r` does),
-- so they only show conflict resolutions.
-- callback(commits) with commits = { { id, short, subject, parent, parents, is_merge, files } }
function M.pr_commits(merge_base, head, callback)
  local template = 'commit_id ++ "\\t" ++ commit_id.short(8) ++ "\\t" ++ parents.map(|c| c.commit_id()).join(" ")'
    .. ' ++ "\\t" ++ description.first_line() ++ "\\n"'
  local revset = string.format("%s..%s", merge_base, head)
  run_async({ "log", "--ignore-working-copy", "--no-graph", "--reversed", "-r", revset, "-T", template }, function(ok, out)
    local commits = {}
    if ok then
      for line in out:gmatch("[^\n]+") do
        local id, short, parents, subject = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if id then
          local parent_list = vim.split(parents, " ", { trimempty = true })
          table.insert(commits, {
            id = id,
            short = short,
            subject = subject ~= "" and subject or "(no description)",
            parent = parent_list[1],
            parents = parent_list,
            is_merge = #parent_list > 1,
            files = {},
          })
        end
      end
    end

    local pending = #commits
    if pending == 0 then
      callback(commits)
      return
    end
    for _, commit in ipairs(commits) do
      run_async({ "diff", "--ignore-working-copy", "-r", commit.id, "-T", diff_entry_template }, function(diff_ok, diff_out)
        commit.files = diff_ok and parse_diff_entries(diff_out) or {}
        pending = pending - 1
        if pending == 0 then
          callback(commits)
        end
      end)
    end
  end)
end

-- Zero-context unified diff of a file in a single commit (against its parents). callback(lines)
function M.diff_commit_file(commit, path, callback)
  run_async({ "diff", "--ignore-working-copy", "--git", "--context", "0", "-r", commit, fileset(path) }, function(ok, out)
    callback(ok and vim.split(out, "\n", { plain = true, trimempty = true }) or {})
  end)
end

-- Replace the review change in the review root with a new one on base_revs whose content is
-- content_rev's tree. git's HEAD then is the diff base, so git tools show the same diff as the plugin.
-- The previous review change is abandoned. callback(ok, err, new_change_id)
function M.move_review_change(base_revs, content_rev, description, callback)
  local previous = M.current_review_pr() and M.current_change()
  local new_cmd = vim.list_extend({ "new" }, base_revs)
  vim.list_extend(new_cmd, { "-m", description })
  local commands = { new_cmd, { "restore", "--from", content_rev } }
  if previous then
    table.insert(commands, { "abandon", previous.change_id })
  end
  run_sequence(commands, function(ok, err)
    if not ok then
      callback(false, err)
      return
    end
    local change = M.current_change()
    callback(true, nil, change and change.change_id)
  end)
end

-- Content of a file at a given revision, as a list of lines. callback(lines or nil if missing)
function M.file_lines_at_async(rev, path, callback)
  run_async({ "file", "show", "--ignore-working-copy", "-r", rev, fileset(path) }, function(ok, out)
    if not ok then
      callback(nil)
      return
    end
    local lines = vim.split(out, "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines)
    end
    callback(lines)
  end)
end

local function read_file(path)
  local f = io.open((M.cwd or vim.fn.getcwd()) .. "/" .. path, "rb")
  if not f then
    return ""
  end
  -- read() returns nil for directories
  local content = f:read("*a")
  f:close()
  return content or ""
end

-- Zero-context unified diff of a file between merge_base and the working copy,
-- in the same format as `git diff --unified=0`. callback(lines)
function M.diff_file(merge_base, path, callback)
  run_async({ "file", "show", "--ignore-working-copy", "-r", merge_base or "trunk()", fileset(path) }, function(ok, old)
    old = ok and old or ""
    local new = read_file(path)
    if old:find("\0", 1, true) or new:find("\0", 1, true) then
      callback({})
      return
    end
    local diff = vim.diff(old, new, { ctxlen = 0 }) or ""
    callback(vim.split(diff, "\n", { plain = true, trimempty = true }))
  end)
end

-- Leave the review.
-- state: { mode, review_change, previous?, workspace?, main_root? }
-- In workspace mode the review workspace is removed from disk; in inplace mode we go back to
-- the change we were on before (previous = { change_id, parents }).
-- In both modes the review change is abandoned.
-- callback(ok, err, description_of_where_we_are)
function M.cleanup_review(state, callback)
  local commands = {}
  local target
  local cwd = state.main_root
  local review_change = state.review_change
  local previous = state.previous

  if state.mode == "workspace" then
    if state.workspace and M.workspaces()[state.workspace] then
      table.insert(commands, { "workspace", "remove", state.workspace })
    end
    target = state.main_root or "main workspace"
  elseif previous and exists(previous.change_id, cwd) then
    table.insert(commands, { "edit", previous.change_id })
    target = previous.change_id:sub(1, 8)
  elseif previous and previous.parents and #previous.parents > 0 then
    -- The previous change was empty and got abandoned by jj, start a new one on its parents
    table.insert(commands, vim.list_extend({ "new" }, previous.parents))
    target = "new change on " .. previous.parents[1]:sub(1, 8)
  else
    table.insert(commands, { "new", "trunk()" })
    target = "new change on trunk()"
  end

  run_sequence(commands, function(ok, err)
    if not ok then
      callback(false, err, target)
      return
    end
    -- Abandon after leaving it, so it is never the working copy of a live workspace
    if review_change and exists(review_change, cwd) then
      run_async({ "abandon", review_change }, function(abandon_ok, _, abandon_err)
        callback(abandon_ok, not abandon_ok and abandon_err or nil, target)
      end, cwd)
    else
      callback(true, nil, target)
    end
  end, cwd)
end

return M
