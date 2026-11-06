local M = {}

M._comments_cache = {}
M._pr_node_ids = {} -- PR number -> GraphQL node id

-- Debug logging helper
local function debug_log(msg)
  local prr = require("prr")
  if prr.config.debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

function M.list_open_prs()
  local prr = require("prr")
  local result = vim.fn.system(
    string.format("gh pr list --state open --limit %d --json number,title,headRefName,baseRefName,author,headRepository,headRepositoryOwner,isCrossRepository,labels,headRefOid",
      prr.config.pr_list_limit)
  )

  if vim.v.shell_error ~= 0 then
    return nil, "Failed to fetch PRs. Make sure 'gh' CLI is installed and authenticated."
  end

  local ok, prs = pcall(vim.fn.json_decode, result)
  if not ok or not prs then
    return nil, "Failed to parse PR data"
  end

  local formatted = {}
  for _, pr in ipairs(prs) do
    -- For fork PRs, use the full reference including owner
    local head_branch = pr.headRefName
    local head_label = pr.headRepositoryOwner and
                      (pr.headRepositoryOwner.login .. ":" .. pr.headRefName) or
                      pr.headRefName

    -- Debug: print what we're getting
    debug_log(string.format("PR #%d: headRefName=%s, owner=%s, repo=%s, url=%s",
                             pr.number,
                             pr.headRefName or "nil",
                             (pr.headRepositoryOwner and pr.headRepositoryOwner.login) or "nil",
                             pr.headRepository and pr.headRepository.name or "nil",
                             pr.headRepository and pr.headRepository.url or "nil"))

    -- Check if it's a cross-repository PR (fork)
    local is_fork = pr.isCrossRepository or false
    local head_repo_owner = nil
    local repo_url = nil

    if is_fork and pr.headRepositoryOwner and pr.headRepository then
      head_repo_owner = pr.headRepositoryOwner.login
      repo_url = string.format("https://github.com/%s/%s.git",
                              head_repo_owner,
                              pr.headRepository.name)
    end

    table.insert(formatted, {
      number = pr.number,
      title = pr.title,
      head_branch = head_branch,
      head_label = head_label,
      base_branch = pr.baseRefName,
      author = pr.author and pr.author.login or "unknown",
      head_repo_owner = is_fork and head_repo_owner or nil,
      head_repo_url = is_fork and repo_url or nil,
    })
  end

  return formatted, nil
end

-- The PR fields needed to start a review of PR pr_number. callback(pr, err)
function M.get_pr_for_review(pr_number, callback)
  local cmd = { "gh", "pr", "view", tostring(pr_number), "--json",
    "number,title,headRefName,baseRefName,headRepositoryOwner,headRepository,isCrossRepository" }
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "gh pr view failed"))
        return
      end
      local ok, info = pcall(vim.json.decode, result.stdout or "")
      if not ok or type(info) ~= "table" then
        callback(nil, "Failed to parse PR details")
        return
      end
      local pr = {
        number = info.number,
        title = info.title,
        head_branch = info.headRefName,
        base_branch = info.baseRefName,
      }
      if info.isCrossRepository and type(info.headRepositoryOwner) == "table" and type(info.headRepository) == "table" then
        pr.head_repo_owner = info.headRepositoryOwner.login
        pr.head_repo_url = string.format("https://github.com/%s/%s.git", pr.head_repo_owner, info.headRepository.name)
        pr.head_label = pr.head_repo_owner .. ":" .. info.headRefName
      end
      callback(pr, nil)
    end)
  end)
end

-- Get detailed PR info including correct branch for forks
function M.get_pr_details(pr_number, callback)
  local cmd = string.format("gh pr view %d --json headRefName,headRepositoryOwner", pr_number)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback(nil, "Failed to fetch PR details")
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, pr = pcall(vim.fn.json_decode, json_str)
      if not ok or not pr then
        vim.schedule(function()
          callback(nil, "Failed to parse PR details")
        end)
        return
      end

      vim.schedule(function()
        local head_branch = pr.headRefName
        local head_label = pr.headRepositoryOwner and
                          (pr.headRepositoryOwner.login .. ":" .. pr.headRefName) or
                          pr.headRefName

        debug_log(string.format("Debug: PR #%d actual branch = %s", pr_number, head_branch))

        callback({
          head_branch = head_branch,
          head_label = head_label,
        }, nil)
      end)
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          callback(nil, "gh pr view failed")
        end)
      end
    end,
  })
end

function M.list_review_requests(callback)
  local prr = require("prr")
  local cmd = string.format(
    "gh pr list --search 'is:open review-requested:@me' --limit %d --json number,title,headRefName,baseRefName,author,updatedAt,additions,deletions,headRepositoryOwner,headRepository,isCrossRepository",
    prr.config.pr_list_limit
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, prs = pcall(vim.fn.json_decode, json_str)
      if not ok or not prs then
        vim.schedule(function()
          callback(nil, "Failed to parse PR data")
        end)
        return
      end

      -- Fetch viewed status for each PR
      local formatted = {}
      local pending = #prs

      if pending == 0 then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      for _, pr in ipairs(prs) do
        local viewed_cmd = string.format(
          "gh pr view %d --json files --jq '[.files[].viewerViewedState] | all(. == \"VIEWED\")'",
          pr.number
        )

        vim.fn.jobstart(viewed_cmd, {
          stdout_buffered = true,
          on_stdout = function(_, viewed_data)
            local is_viewed = false
            if viewed_data and viewed_data[1] then
              is_viewed = viewed_data[1] == "true"
            end

            -- For fork PRs, use the full reference including owner
            local head_branch = pr.headRefName
            local head_label = pr.headRepositoryOwner and
                              (pr.headRepositoryOwner.login .. ":" .. pr.headRefName) or
                              pr.headRefName

            -- Check if it's a cross-repository PR (fork)
            local is_fork = pr.isCrossRepository or false
            local head_repo_owner = nil
            local repo_url = nil

            if is_fork and pr.headRepositoryOwner and pr.headRepository then
              head_repo_owner = pr.headRepositoryOwner.login
              repo_url = string.format("https://github.com/%s/%s.git",
                                      head_repo_owner,
                                      pr.headRepository.name)
            end

            table.insert(formatted, {
              number = pr.number,
              title = pr.title,
              head_branch = head_branch,
              head_label = head_label,
              base_branch = pr.baseRefName,
              author = pr.author and pr.author.login or "unknown",
              updated_at = pr.updatedAt,
              additions = pr.additions or 0,
              deletions = pr.deletions or 0,
              viewed = is_viewed,
              head_repo_owner = is_fork and head_repo_owner or nil,
              head_repo_url = is_fork and repo_url or nil,
            })

            pending = pending - 1
            if pending == 0 then
              -- Sort by viewed status (unviewed first) then by number
              table.sort(formatted, function(a, b)
                if a.viewed ~= b.viewed then
                  return not a.viewed
                end
                return a.number > b.number
              end)

              vim.schedule(function()
                callback(formatted, nil)
              end)
            end
          end,
          on_exit = function(_, code)
            if code ~= 0 then
              pending = pending - 1
              table.insert(formatted, {
                number = pr.number,
                title = pr.title,
                head_branch = pr.headRefName,
                base_branch = pr.baseRefName,
                author = pr.author and pr.author.login or "unknown",
                updated_at = pr.updatedAt,
                additions = pr.additions or 0,
                deletions = pr.deletions or 0,
                viewed = false,
              })

              if pending == 0 then
                table.sort(formatted, function(a, b)
                  if a.viewed ~= b.viewed then
                    return not a.viewed
                  end
                  return a.number > b.number
                end)

                vim.schedule(function()
                  callback(formatted, nil)
                end)
              end
            end
          end,
        })
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end


function M.get_pr_info(pr_number, callback)
  local cmd = string.format(
    "gh pr view %d --json number,title,body,author,state,additions,deletions,changedFiles,reviews,comments,headRefName,baseRefName,createdAt,updatedAt,mergeable,reviewDecision",
    pr_number
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback(nil, "Failed to fetch PR info")
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, info = pcall(vim.fn.json_decode, json_str)
      if not ok or not info then
        vim.schedule(function()
          callback(nil, "Failed to parse PR info")
        end)
        return
      end

      local review_counts = {
        approved = 0,
        changes_requested = 0,
        commented = 0,
        pending = 0,
      }

      local reviewers = {
        approved = {},
        changes_requested = {},
      }

      if info.reviews then
        for _, review in ipairs(info.reviews) do
          local state = review.state:lower()
          local reviewer = review.author and review.author.login or "unknown"
          if state == "approved" then
            review_counts.approved = review_counts.approved + 1
            if not vim.tbl_contains(reviewers.approved, reviewer) then
              table.insert(reviewers.approved, reviewer)
            end
          elseif state == "changes_requested" then
            review_counts.changes_requested = review_counts.changes_requested + 1
            if not vim.tbl_contains(reviewers.changes_requested, reviewer) then
              table.insert(reviewers.changes_requested, reviewer)
            end
          elseif state == "commented" then
            review_counts.commented = review_counts.commented + 1
          elseif state == "pending" then
            review_counts.pending = review_counts.pending + 1
          end
        end
      end

      vim.schedule(function()
        callback({
          number = info.number,
          title = info.title,
          body = info.body or "",
          author = info.author and info.author.login or "unknown",
          state = info.state,
          head_branch = info.headRefName,
          base_branch = info.baseRefName,
          additions = info.additions or 0,
          deletions = info.deletions or 0,
          changed_files = info.changedFiles or 0,
          comments_count = info.comments and #info.comments or 0,
          reviews = review_counts,
          reviewers = reviewers,
          review_decision = info.reviewDecision,
          mergeable = info.mergeable,
          created_at = info.createdAt,
          updated_at = info.updatedAt,
        }, nil)
      end)
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

function M.get_pr_checks(pr_number, callback)
  local cmd = string.format("gh pr checks %d --json name,state,conclusion,detailsUrl", pr_number)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback({}, nil) -- Return empty array if no checks
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, checks = pcall(vim.fn.json_decode, json_str)
      if not ok or not checks then
        vim.schedule(function()
          callback({}, nil) -- Return empty array on parse error
        end)
        return
      end

      vim.schedule(function()
        callback(checks, nil)
      end)
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback({}, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

-- Fetch global/issue comments (not line-specific comments)
function M.fetch_pr_global_comments(pr_number, callback)
  -- First, fetch issue comments
  local cmd_comments = string.format(
    "gh api --paginate repos/{owner}/{repo}/issues/%d/comments --jq '.[] | {id: .id, body: .body, user: .user.login, created_at: .created_at, type: \"comment\"}'",
    pr_number
  )

  -- Also fetch PR reviews (approvals, rejections, etc)
  local cmd_reviews = string.format(
    "gh api --paginate repos/{owner}/{repo}/pulls/%d/reviews --jq '.[] | {id: .id, body: .body, user: .user.login, created_at: .submitted_at, state: .state, type: \"review\"}'",
    pr_number
  )

  local all_comments = {}
  local completed = 0
  local total = 2

  local function check_complete()
    completed = completed + 1
    if completed == total then
      -- Sort by date
      table.sort(all_comments, function(a, b)
        return a.created_at < b.created_at
      end)

      vim.schedule(function()
        callback(all_comments, nil)
      end)
    end
  end

  -- Fetch issue comments
  vim.fn.jobstart(cmd_comments, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 and not (data[1] == "" and #data == 1) then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            local ok, comment = pcall(vim.fn.json_decode, line)
            if ok and comment then
              table.insert(all_comments, {
                id = comment.id,
                body = comment.body,
                user = comment.user,
                created_at = comment.created_at,
                type = "comment",
              })
            end
          end
        end
      end
    end,
    on_exit = function()
      check_complete()
    end,
  })

  -- Fetch PR reviews
  vim.fn.jobstart(cmd_reviews, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 and not (data[1] == "" and #data == 1) then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            local ok, review = pcall(vim.fn.json_decode, line)
            if ok and review then
              -- Format state nicely
              local state_text = ""
              if review.state == "APPROVED" then
                state_text = "✅ Approved this pull request"
              elseif review.state == "CHANGES_REQUESTED" then
                state_text = "❌ Requested changes"
              elseif review.state == "COMMENTED" then
                state_text = "💬 Reviewed"
              elseif review.state == "DISMISSED" then
                state_text = "🚫 Review dismissed"
              else
                state_text = review.state
              end

              -- Combine state and body
              local full_body = state_text
              if review.body and review.body ~= "" and review.body ~= vim.NIL then
                full_body = state_text .. "\n\n" .. review.body
              end

              table.insert(all_comments, {
                id = review.id,
                body = full_body,
                user = review.user,
                created_at = review.created_at or review.submitted_at,
                type = "review",
                state = review.state,
              })
            end
          end
        end
      end
    end,
    on_exit = function()
      check_complete()
    end,
  })
end

function M.fetch_pr_comments(pr_number, callback)
  if M._comments_cache[pr_number] then
    callback(M._comments_cache[pr_number], nil)
    return
  end

  local cmd = string.format(
    "gh api --paginate repos/{owner}/{repo}/pulls/%d/comments --jq '.[] | {id: .id, path: .path, line: (.line // .original_line), original_line: .original_line, original_commit_id: .original_commit_id, body: .body, user: .user.login, created_at: .created_at, in_reply_to_id: .in_reply_to_id}'",
    pr_number
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 or (data[1] == "" and #data == 1) then
        M._comments_cache[pr_number] = {}
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      local comments = {}
      for _, line in ipairs(data) do
        if line and line ~= "" then
          local ok, comment = pcall(vim.fn.json_decode, line)
          if ok and comment then
            -- Ensure line is a number (handle vim.NIL from JSON null)
            local line_num = comment.line
            if line_num == vim.NIL or type(line_num) ~= "number" then
              line_num = nil
            end

            local original_line = comment.original_line
            if type(original_line) ~= "number" then
              original_line = nil
            end
            local original_commit_id = comment.original_commit_id
            if type(original_commit_id) ~= "string" then
              original_commit_id = nil
            end

            table.insert(comments, {
              id = comment.id,
              path = comment.path,
              line = line_num,
              original_line = original_line,
              original_commit_id = original_commit_id,
              body = comment.body,
              user = comment.user,
              created_at = comment.created_at,
              in_reply_to_id = comment.in_reply_to_id,
              reactions = {},
            })
          end
        end
      end

      -- Fetch reactions for all comments
      if #comments == 0 then
        M._comments_cache[pr_number] = comments
        vim.schedule(function()
          callback(comments, nil)
        end)
        return
      end

      local pending = #comments
      for _, comment in ipairs(comments) do
        M.get_comment_reactions(comment.id, function(reactions, err)
          if not err and reactions then
            comment.reactions = reactions
          end

          pending = pending - 1
          if pending == 0 then
            M._comments_cache[pr_number] = comments
            vim.schedule(function()
              callback(comments, nil)
            end)
          end
        end)
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

function M.get_comments_for_file(pr_number, file_path, callback)
  M.fetch_pr_comments(pr_number, function(comments, err)
    if err then
      callback(nil, err)
      return
    end

    local file_comments = {}
    for _, comment in ipairs(comments or {}) do
      if comment.path == file_path then
        table.insert(file_comments, comment)
      end
    end

    callback(file_comments, nil)
  end)
end

function M.clear_cache()
  M._comments_cache = {}
end

function M.get_current_user(callback)
  vim.fn.jobstart("gh api user --jq '.login'", {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(data[1]:gsub("%s+", ""), nil)
        end)
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

-- Submit a review with comments and event (APPROVE, REQUEST_CHANGES, or COMMENT)
function M.approve_pr(pr_number, body, callback)
  local cmd
  if body and body ~= "" then
    cmd = string.format("gh pr review %d --approve --body %s", pr_number, vim.fn.shellescape(body))
  else
    cmd = string.format("gh pr review %d --approve", pr_number)
  end

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to approve PR")
        end
      end)
    end,
  })
end

function M.request_changes(pr_number, body, callback)
  if not body or body == "" then
    callback(false, "Body is required when requesting changes")
    return
  end

  local cmd = string.format("gh pr review %d --request-changes --body %s", pr_number, vim.fn.shellescape(body))

  local stderr_output = {}
  vim.fn.jobstart(cmd, {
    stderr_buffered = true,
    on_stderr = function(_, err_data)
      if err_data then
        vim.list_extend(stderr_output, err_data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          local err_msg = table.concat(stderr_output, "\n")
          callback(false, "Failed to request changes: " .. err_msg)
        end
      end)
    end,
  })
end

function M.add_pr_comment(pr_number, body, callback)
  local cmd = string.format("gh pr comment %d --body %s", pr_number, vim.fn.shellescape(body))

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to add comment")
        end
      end)
    end,
  })
end

-- Commit that new single review comments are attached to; nil means the PR head.
-- Set while reviewing a single commit (commit mode).
M.comment_commit_id = nil

function M.add_review_comment(pr_number, path, line, body, callback, start_line)
  local get_head_cmd = string.format("gh pr view %d --json headRefOid --jq '.headRefOid'", pr_number)
  if M.comment_commit_id then
    get_head_cmd = "echo " .. M.comment_commit_id
  end

  vim.fn.jobstart(get_head_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback(false, "Failed to get PR head commit")
        end)
        return
      end

      local commit_id = data[1]:gsub("%s+", "")

      local comment_data = {
        body = body,
        path = path,
        line = line,
        side = "RIGHT",
        commit_id = commit_id,
      }

      -- For multi-line comments, add start_line and start_side
      if start_line and start_line ~= line then
        comment_data.start_line = start_line
        comment_data.start_side = "RIGHT"
      end

      local json_body = vim.fn.json_encode(comment_data)

      local cmd = string.format(
        "gh api repos/{owner}/{repo}/pulls/%d/comments -X POST --input -",
        pr_number
      )

      local stderr_output = {}
      local job_id = vim.fn.jobstart(cmd, {
        stderr_buffered = true,
        on_stderr = function(_, err_data)
          if err_data then
            stderr_output = err_data
          end
        end,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              M._comments_cache[pr_number] = nil
              callback(true, nil)
            else
              local err_msg = table.concat(stderr_output, "\n")
              callback(false, "Failed to add review comment: " .. err_msg)
            end
          end)
        end,
      })

      vim.fn.chansend(job_id, json_body)
      vim.fn.chanclose(job_id, "stdin")
    end,
  })
end

function M.reply_to_comment(pr_number, comment_id, body, callback)
  local json_body = vim.fn.json_encode({
    body = body,
    in_reply_to = comment_id,
  })

  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/%d/comments -X POST --input -",
    pr_number
  )

  local job_id = vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          callback(false, "Failed to reply to comment")
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, json_body)
  vim.fn.chanclose(job_id, "stdin")
end

function M.edit_comment(pr_number, comment_id, body, callback)
  local json_body = vim.fn.json_encode({
    body = body,
  })

  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d -X PATCH --input -",
    comment_id
  )

  local job_id = vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          callback(false, "Failed to edit comment")
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, json_body)
  vim.fn.chanclose(job_id, "stdin")
end

function M.delete_comment(pr_number, comment_id, callback)
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d -X DELETE",
    comment_id
  )

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          callback(false, "Failed to delete comment")
        end
      end)
    end,
  })
end

-- Helper function to create a pending review with comments
-- ===== Pending review (GitHub's own draft review: one per PR and user, only visible to them) =====

-- Run a GraphQL query. String variables go in vars (-f, raw); numbers and the {owner} / {repo}
-- placeholders, which gh only fills in -F fields, go in typed_vars.
-- callback(data, err)
local function graphql(query, vars, typed_vars, callback)
  local cmd = { "gh", "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars or {}) do
    vim.list_extend(cmd, { "-f", k .. "=" .. v })
  end
  for k, v in pairs(typed_vars or {}) do
    vim.list_extend(cmd, { "-F", k .. "=" .. tostring(v) })
  end
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr ~= "" and result.stderr or result.stdout or "gh api graphql failed"))
        return
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout or "", { luanil = { object = true, array = true } })
      if not ok or type(decoded) ~= "table" then
        callback(nil, "Failed to parse GraphQL response")
        return
      end
      callback(decoded.data, nil)
    end)
  end)
end

local PENDING_REVIEW_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      reviews(states: PENDING, first: 1) {
        nodes {
          id
          comments(first: 100) {
            nodes {
              id databaseId path line originalLine startLine originalStartLine body createdAt
              author { login }
            }
          }
        }
      }
    }
  }
}]]

-- The current user's pending review of the PR. callback(review, err), review = nil when there is
-- none, else { id = node id, comments = { { id (database id), node_id, path, line, start_line, body,
-- user, created_at, is_pending = true } } }
function M.fetch_pending_review(pr_number, callback)
  graphql(PENDING_REVIEW_QUERY, nil, { owner = "{owner}", repo = "{repo}", number = pr_number }, function(data, err)
    local pr = data and data.repository and data.repository.pullRequest
    if not pr then
      callback(nil, err or "PR not found")
      return
    end
    M._pr_node_ids[pr_number] = pr.id
    local node = pr.reviews.nodes[1]
    if not node then
      callback(nil, nil)
      return
    end
    local review = { id = node.id, comments = {} }
    for _, c in ipairs(node.comments.nodes) do
      table.insert(review.comments, {
        id = c.databaseId,
        node_id = c.id,
        path = c.path,
        line = c.line or c.originalLine,
        start_line = c.startLine or c.originalStartLine,
        body = c.body,
        user = c.author and c.author.login,
        created_at = c.createdAt,
        is_pending = true,
        reactions = {},
      })
    end
    callback(review, nil)
  end)
end

-- Comments of the current user's pending review. callback(comments, err)
function M.get_pending_review_comments(pr_number, callback)
  M.fetch_pending_review(pr_number, function(review, err)
    callback(review and review.comments or {}, err)
  end)
end

-- Pending review mutations run one at a time, so two quick adds don't both create a review
local pending_queue, pending_running = {}, false

local function run_pending_queue()
  if pending_running or #pending_queue == 0 then
    return
  end
  pending_running = true
  local job = table.remove(pending_queue, 1)
  job(function()
    pending_running = false
    run_pending_queue()
  end)
end

local function enqueue_pending(job)
  table.insert(pending_queue, job)
  run_pending_queue()
end

-- The pending review's node id, creating the review if there is none. callback(review_id, err)
local function ensure_pending_review(pr_number, callback)
  M.fetch_pending_review(pr_number, function(review, err)
    if review then
      callback(review.id)
      return
    end
    if err then
      callback(nil, err)
      return
    end
    graphql([[mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }]],
      { pr = M._pr_node_ids[pr_number] }, nil, function(data, create_err)
        local created = data and data.addPullRequestReview and data.addPullRequestReview.pullRequestReview
        callback(created and created.id, create_err or (not created and "Failed to create pending review" or nil))
      end)
  end)
end

-- Add a comment on the PR head (lines start_line..line of the new side; start_line optional) to the
-- current user's pending review, creating it if needed. callback(ok, err)
function M.add_pending_comment(pr_number, path, line, body, start_line, callback)
  enqueue_pending(function(done)
    local function finish(ok, err)
      done()
      callback(ok, err)
    end
    ensure_pending_review(pr_number, function(review_id, err)
      if not review_id then
        finish(false, err)
        return
      end
      local vars = { review = review_id, path = path, body = body }
      local typed = { line = line }
      local range_params, range_args = "", ""
      if start_line and start_line ~= line then
        typed.startLine = start_line
        range_params, range_args = ", $startLine: Int!", ", startLine: $startLine, startSide: RIGHT"
      end
      local query = string.format([[
mutation($review: ID!, $path: String!, $body: String!, $line: Int!%s) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, body: $body, line: $line, side: RIGHT%s}) {
    thread { id }
  }
}]], range_params, range_args)
      graphql(query, vars, typed, function(data, add_err)
        local thread = data and data.addPullRequestReviewThread and data.addPullRequestReviewThread.thread
        finish(thread ~= nil, add_err or (not thread and "GitHub did not create the comment" or nil))
      end)
    end)
  end)
end

-- Edit a comment of the pending review (node_id from fetch_pending_review). callback(ok, err)
function M.edit_pending_comment(node_id, body, callback)
  graphql([[mutation($id: ID!, $body: String!) {
  updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $body}) { pullRequestReviewComment { id } }
}]], { id = node_id, body = body }, nil, function(data, err)
    callback(data ~= nil, err)
  end)
end

-- Delete a comment of the pending review (node_id from fetch_pending_review). callback(ok, err)
function M.delete_pending_comment(node_id, callback)
  graphql([[mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }]],
    { id = node_id }, nil, function(data, err)
      callback(data ~= nil, err)
    end)
end

-- Submit the current user's pending review with event "COMMENT" | "APPROVE" | "REQUEST_CHANGES".
-- callback(ok, err, submitted): submitted = false when there is no pending review (nothing was sent)
function M.submit_pending_review(pr_number, event, body, callback)
  enqueue_pending(function(done)
    M.fetch_pending_review(pr_number, function(review, err)
      if not review then
        done()
        callback(err == nil, err, false)
        return
      end
      graphql([[mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String!) {
  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) { pullRequestReview { id } }
}]], { review = review.id, event = event, body = body or "" }, nil, function(data, submit_err)
        done()
        if data then
          M._comments_cache[pr_number] = nil
        end
        callback(data ~= nil, submit_err, data ~= nil)
      end)
    end)
  end)
end

function M.get_comment_reactions(comment_id, callback)
  -- PR review comments use /pulls/comments, not /issues/comments
  local cmd = string.format(
    "gh api --paginate repos/{owner}/{repo}/pulls/comments/%d/reactions --jq '.[] | {id: .id, content: .content, user: .user.login}'",
    comment_id
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 or (data[1] == "" and #data == 1) then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      local reactions = {}
      for _, line in ipairs(data) do
        if line and line ~= "" then
          local ok, reaction = pcall(vim.fn.json_decode, line)
          if ok and reaction then
            table.insert(reactions, {
              id = reaction.id,
              content = reaction.content,
              user = reaction.user,
            })
          end
        end
      end

      vim.schedule(function()
        callback(reactions, nil)
      end)
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

-- Add a reaction to a comment
-- content can be: "+1", "-1", "laugh", "confused", "heart", "hooray", "rocket", "eyes"
function M.add_comment_reaction(comment_id, content, callback)
  local json_body = vim.fn.json_encode({
    content = content,
  })

  -- PR review comments use /pulls/comments, not /issues/comments
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d/reactions -X POST --input - -H 'Accept: application/vnd.github+json'",
    comment_id
  )

  local stderr_output = {}
  local stdout_output = {}
  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_output, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_output, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          local err_msg = table.concat(stderr_output, "\n")
          local out_msg = table.concat(stdout_output, "\n")
          local full_error = err_msg ~= "" and err_msg or out_msg
          callback(false, full_error ~= "" and full_error or "Failed to add reaction (unknown error)")
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, json_body)
  vim.fn.chanclose(job_id, "stdin")
end

-- Remove a reaction from a comment
function M.remove_comment_reaction(comment_id, reaction_id, callback)
  -- PR review comments use /pulls/comments, not /issues/comments
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d/reactions/%d -X DELETE -H 'Accept: application/vnd.github+json'",
    comment_id,
    reaction_id
  )

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to remove reaction")
        end
      end)
    end,
  })
end

-- ===== Viewed files (GitHub's per-file "Viewed" checkbox, per user) =====

local VIEWED_FILES_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      files(first: 100, after: $endCursor) {
        nodes { path viewerViewedState }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}]]

-- Viewed state of the PR's files for the current user.
-- callback(states, err), states: path -> "VIEWED" | "UNVIEWED" | "DISMISSED" (viewed, then changed)
function M.fetch_viewed_files(pr_number, callback)
  local cmd = { "gh", "api", "graphql", "--paginate",
    "-F", "owner={owner}", "-F", "repo={repo}", "-F", "number=" .. pr_number,
    "-f", "query=" .. VIEWED_FILES_QUERY,
    "--jq", [[.data.repository.pullRequest | "ID\t\(.id)", (.files.nodes[] | "\(.viewerViewedState)\t\(.path)")]] }
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "gh api graphql failed"))
        return
      end
      local states = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local key, value = line:match("^([^\t]+)\t(.+)$")
        if key == "ID" then
          M._pr_node_ids[pr_number] = value
        elseif key then
          states[value] = key
        end
      end
      callback(states, nil)
    end)
  end)
end

local function get_pr_node_id(pr_number, callback)
  if M._pr_node_ids[pr_number] then
    callback(M._pr_node_ids[pr_number])
    return
  end
  vim.system({ "gh", "pr", "view", tostring(pr_number), "--json", "id", "--jq", ".id" }, { text = true }, function(result)
    vim.schedule(function()
      local id = result.code == 0 and vim.trim(result.stdout or "") or ""
      if id == "" then
        callback(nil, vim.trim(result.stderr or "gh pr view failed"))
        return
      end
      M._pr_node_ids[pr_number] = id
      callback(id)
    end)
  end)
end

-- Mutations run one at a time, in order, so quick toggles of a file end in its last state
local viewed_queue, viewed_running = {}, false

local function process_viewed_queue()
  if viewed_running or #viewed_queue == 0 then
    return
  end
  viewed_running = true
  local job = table.remove(viewed_queue, 1)
  local function done(ok, err)
    viewed_running = false
    if job.callback then
      job.callback(ok, err)
    end
    process_viewed_queue()
  end
  get_pr_node_id(job.pr_number, function(node_id, err)
    if not node_id then
      done(false, err)
      return
    end
    local mutation = job.viewed and "markFileAsViewed" or "unmarkFileAsViewed"
    local query = string.format(
      "mutation($pr: ID!, $path: String!) { %s(input: {pullRequestId: $pr, path: $path}) { clientMutationId } }",
      mutation)
    vim.system({ "gh", "api", "graphql", "-f", "query=" .. query, "-f", "pr=" .. node_id, "-f", "path=" .. job.path },
      { text = true }, function(result)
        vim.schedule(function()
          done(result.code == 0, result.code ~= 0 and vim.trim(result.stderr or "") or nil)
        end)
      end)
  end)
end

-- Mark (viewed = true) or unmark a file as viewed on GitHub. callback(ok, err)
function M.set_file_viewed(pr_number, path, viewed, callback)
  for _, job in ipairs(viewed_queue) do
    if job.pr_number == pr_number and job.path == path then
      job.viewed, job.callback = viewed, callback
      return
    end
  end
  table.insert(viewed_queue, { pr_number = pr_number, path = path, viewed = viewed, callback = callback })
  process_viewed_queue()
end

return M
