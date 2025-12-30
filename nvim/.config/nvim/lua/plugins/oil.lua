vim.pack.add({"https://github.com/stevearc/oil.nvim"})

require "oil".setup({
  view_options = {
    show_hidden = true,
  },
  preview_win = {
    update_on_cursor_moved = true,
    preview_method = "fast_scratch",
    disable_preview = function()
      return false
    end,
    win_options = {
      wrap = true,
    },
  },
})
