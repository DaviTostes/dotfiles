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

-- dadbod
vim.keymap.set("n", "<leader>tb", "<C-:>DBUI<CR>", {})

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

-- Toast
vim.keymap.set({"n", "v"}, "<leader>t", ":Toast<CR>", { desc = 'Toast: Generate completion' })

-- Omm
vim.keymap.set({"n", "v"}, "<leader>o", ":Omm<CR>", { desc = 'Omm: Task Manager' })
