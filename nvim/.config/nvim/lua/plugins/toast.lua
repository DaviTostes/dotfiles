vim.opt.runtimepath:prepend("/home/toast/toast-nvim")

require "toast".setup({
  model = "anthropic/claude-opus-4.6"
})
