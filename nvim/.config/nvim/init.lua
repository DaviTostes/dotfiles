vim.filetype.add({
  extension = {
    bru = "bru",
  }
})

for _, file in ipairs(vim.fn.glob(vim.fn.stdpath("config") .. "/lua/plugins/*.lua", false, true)) do
  local name = vim.fn.fnamemodify(file, ":t:r")
  if name ~= "init" then
    require("plugins." .. name)
  end
end

require "vim-options"
require "keymaps"

vim.api.nvim_create_autocmd("FileType", {
    callback = function(args)
        pcall(vim.treesitter.start, args.buf)
    end,
})
