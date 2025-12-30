vim.pack.add({
  { src = "https://github.com/nvim-mini/mini.icons" },
  { src = "https://github.com/nvim-mini/mini.pick" },
  { src = "https://github.com/nvim-mini/mini.visits" },
  { src = "https://github.com/nvim-mini/mini.statusline" },
  { src = "https://github.com/nvim-mini/mini-git" },
  { src = "https://github.com/nvim-mini/mini.diff" },
})

require "mini.icons".setup({
  extension = {
    bru = { glyph = '󰖟', hl = 'MiniIconsOrange' },
  },
  filetype = {
    bru = { glyph = '󰖟', hl = 'MiniIconsOrange' },
  },
})

require "mini.pick".setup({
  mappings = {
    move_down = '<C-j>',
    move_up = '<C-k>',
  }
})

require "mini.visits".setup({})

require "mini.git".setup({})
require "mini.diff".setup({})

local function truncated_filename()
  local full = vim.api.nvim_buf_get_name(0)
  if full == "" then
    return "[No Name]"
  end

  local parts = vim.split(full, "/")
  local count = #parts

  local start = math.max(1, count - 2)

  return table.concat(vim.list_slice(parts, start, count), "/")
end

local statusline = require('mini.statusline')
statusline.setup({
  content = {
    active = function()
      local mode, mode_hl = statusline.section_mode({ trunc_width = 120 })
      local git           = statusline.section_git({ trunc_width = 75 })
      local diagnostics   = statusline.section_diagnostics({ trunc_width = 75 })
      local filename      = truncated_filename()
      local location      = statusline.section_location({ trunc_width = 75 })

      local lsp           = function()
        local clients = vim.lsp.get_clients({ bufnr = 0 })
        if #clients == 0 then
          return ""
        end
        local names = {}
        for _, client in ipairs(clients) do
          table.insert(names, client.name)
        end
        return " " .. table.concat(names, ", ")
      end

      return statusline.combine_groups({
        { hl = mode_hl,                  strings = { mode } },
        { hl = 'MiniStatuslineDevinfo',  strings = { git, diagnostics } },
        { hl = 'MiniStatuslineFilename', strings = { filename } },
        '%=',
        { hl = 'MiniStatuslineLsp', strings = { lsp() } },
        { hl = mode_hl,             strings = { location } },
      })
    end,
  },
  use_icons = true,
})
