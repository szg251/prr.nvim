if vim.g.loaded_prr then
  return
end
vim.g.loaded_prr = true

vim.api.nvim_create_user_command("PRReview", function()
  require("prr").review_pr()
end, { desc = "Select and review a GitHub PR" })

vim.api.nvim_create_user_command("PRReviewCleanup", function()
  require("prr").cleanup_review_branch()
end, { desc = "Exit the review and clean up its jj workspace or change" })
