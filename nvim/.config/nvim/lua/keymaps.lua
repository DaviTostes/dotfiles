vim.keymap.set('n', '<leader>w', ':write<CR>')
vim.keymap.set('n', '<leader>q', ':quit<CR>')
vim.keymap.set('n', '<leader>u', function()
  local ok, err = pcall(vim.pack.update)
  if not ok then
    vim.notify('Pack update failed: ' .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify('Pack update completed', vim.log.levels.INFO)
  end
end)

-- diagnostics
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
vim.keymap.set("n", "<leader>d", vim.diagnostic.open_float, {})

-- lsp
vim.keymap.set("n", "K", vim.lsp.buf.hover, {})
vim.keymap.set("n", "gd", vim.lsp.buf.definition, {})
vim.keymap.set("n", "gD", vim.lsp.buf.declaration, {})
vim.keymap.set({ "n", "v" }, "<space>ca", vim.lsp.buf.code_action, {})
vim.keymap.set("n", "<leader>lf", vim.lsp.buf.format, {})
vim.keymap.set("n", "<leader>lr", ':lsp restart<CR>')

-- oil
vim.keymap.set("n", "<leader>e", "<CMD>Oil<CR>", {})

-- tmux
vim.keymap.set("n", "<C-h>", "<cmd> TmuxNavigateLeft<CR>", { desc = "Window left" })
vim.keymap.set("n", "<C-l>", "<cmd> TmuxNavigateRight<CR>", { desc = "Window right" })
vim.keymap.set("n", "<C-j>", "<cmd> TmuxNavigateDown<CR>", { desc = "Window down" })
vim.keymap.set("n", "<C-k>", "<cmd> TmuxNavigateUp<CR>", { desc = "Window up" })

-- mini.visits
vim.keymap.set("n", "<leader>v", ":lua MiniVisits.select_path()<CR>")

-- mini.pick
vim.keymap.set('n', "<leader>f", ":Pick files<CR>")

-- bafa
vim.keymap.set('n', '<leader>m', function()
  require 'bafa'.toggle()
end)

-- mini.git
vim.keymap.set('v', '<leader>gb', function()
  MiniGit.show_range_history()
end, { desc = 'Git blame visual selection' })

-- treesiter
local select = require("nvim-treesitter-textobjects.select")

vim.keymap.set({ "x", "o" }, "af", function()
  select.select_textobject("@function.outer", "textobjects")
end)

vim.keymap.set({ "x", "o" }, "if", function()
  select.select_textobject("@function.inner", "textobjects")
end)

local move = require("nvim-treesitter-textobjects.move")

vim.keymap.set("n", "]f", function()
  move.goto_next_start("@function.outer")
end)

vim.keymap.set("n", "[f", function()
  move.goto_previous_start("@function.outer")
end)

vim.keymap.set("n", "]c", function()
  move.goto_next_start("@class.outer")
end)

vim.keymap.set("n", "[c", function()
  move.goto_previous_start("@class.outer")
end)
