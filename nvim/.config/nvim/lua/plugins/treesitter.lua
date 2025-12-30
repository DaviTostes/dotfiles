vim.pack.add({ "https://github.com/nvim-treesitter/nvim-treesitter" })

local treesitter = require "nvim-treesitter"

treesitter.setup {
  install_dir = vim.fn.stdpath('data') .. '/site'
}

treesitter.install {
  "lua",
  "javascript",
  "typescript",
  "html",
  "css",
  "c_sharp",
  "go",
  "gotmpl",
  "python",
  "regex"
}

vim.api.nvim_create_autocmd("FileType", {
    callback = function(args)
        pcall(vim.treesitter.start, args.buf)
    end,
})
