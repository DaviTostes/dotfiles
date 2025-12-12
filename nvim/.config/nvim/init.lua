vim.pack.add(
  {
    -- themes
    { src = "https://github.com/vague2k/vague.nvim" },
    -- style
    { src = "https://github.com/tribela/transparent.nvim" },
    { src = "https://github.com/nvim-treesitter/nvim-treesitter" },
    -- dadbod
    { src = "https://github.com/kristijanhusak/vim-dadbod-ui" },
    { src = "https://github.com/tpope/vim-dadbod" },
    { src = "https://github.com/kristijanhusak/vim-dadbod-completion" },
    -- utils
    { src = "https://github.com/m4xshen/autoclose.nvim" },
    { src = "https://github.com/stevearc/oil.nvim" },
    { src = "https://github.com/christoomey/vim-tmux-navigator" },
    { src = "https://github.com/mg979/vim-visual-multi" },
    { src = "https://github.com/github/copilot.vim" },
    -- lsp
    { src = "https://github.com/neovim/nvim-lspconfig" },
    -- snippets
    { src = "https://github.com/hrsh7th/nvim-cmp" },
    { src = "https://github.com/hrsh7th/cmp-nvim-lsp" },
    { src = "https://github.com/L3MON4D3/LuaSnip" },
    { src = "https://github.com/saadparwaiz1/cmp_luasnip" },
    -- mini
    { src = "https://github.com/nvim-mini/mini.icons" },
    { src = "https://github.com/nvim-mini/mini.pick" },
    { src = "https://github.com/nvim-mini/mini.visits" },
    { src = "https://github.com/nvim-mini/mini.statusline" },
    { src = "https://github.com/nvim-mini/mini-git" },
    { src = "https://github.com/nvim-mini/mini.diff" },
    { src = "https://github.com/rafamadriz/friendly-snippets" },
  }
)

vim.api.nvim_create_autocmd({"BufRead", "BufNewFile"}, {
  pattern = "*.bru",
  callback = function()
    vim.bo.filetype = "bruno"
    vim.bo.syntax = "bruno"
  end,
})

vim.filetype.add({
  extension = {
    bru = "bruno",
  }
})

vim.filetype.add({
  extension = {
    bru = "bruno",
  }
})

require "mini.icons".setup()

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

require "transparent".setup({
  auto = true
})

require "nvim-treesitter.configs".setup({
  ensure_installed = {
    "lua",
    "javascript",
    "html",
    "css",
    "c_sharp",
    "go",
    "gotmpl",
    "python",
    "regex",
  },
  auto_install = true,
  highlight = { enable = true },
  indent = { enable = true },
})

local on_attach = function(client, bufnr)
  client.server_capabilities.semanticTokensProvider = nil

  client.server_capabilities.documentHighlighProvider = nil
  client.server_capabilities.codeLensProvider = nil

  if client.server_capabilities.documentFormattingProvider then
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      callback = vim.lsp.buf.format,
    })
  end
end

local cmp = require "cmp"
local luasnip = require "luasnip"

require "luasnip.loaders.from_vscode".lazy_load()

local capabilities = require "cmp_nvim_lsp".default_capabilities()

cmp.setup({
  snippet = {
    expand = function(args)
      luasnip.lsp_expand(args.body)
    end
  },
  window = {
    completion = cmp.config.window.bordered(),
    documentation = cmp.config.window.bordered(),
  },
  mapping = cmp.mapping.preset.insert({
    ["<C-b>"] = cmp.mapping.scroll_docs(-4),
    ["<C-f>"] = cmp.mapping.scroll_docs(4),
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<C-e>"] = cmp.mapping.abort(),
    ["<CR>"] = cmp.mapping.confirm({ select = true }),
    ["<C-j>"] = cmp.mapping.select_next_item(),
    ["<C-k>"] = cmp.mapping.select_prev_item(),
  }),
  sources = cmp.config.sources({
    { name = "nvim_lsp" },
    { name = "luasnip" },
    { name = "path" },
    { name = "buffer" },
  }),
})

vim.lsp.enable({
  "ts_ls",
  "pyright",
  "lua_ls",
  "gopls",
  "dartls",
  "html",
  "csharp_ls",
  "jsonls",
  "cssls",
  "htmx",
})

vim.lsp.config("ts_ls", {
  capabilities = capabilities,
  on_attach = on_attach,
  init_options = {
    maxTsServerMemory = 512
  }
})

vim.lsp.config("pyright", {
  capabilities = capabilities,
  on_attach = on_attach,
})

vim.lsp.config("lua_ls", {
  capabilities = capabilities,
  on_attach = on_attach,
  settings = {
    Lua = {
      runtime = {
        version = "LuaJIT"
      },
      diagnostics = {
        globals = {
          "vim"
        }
      },
      workspace = {
        library = {
          "runtime/lua"
        },
        checkThirdParty = false
      }
    },
  },
})


vim.lsp.config("gopls", {
  capabilities = capabilities,
  on_attach = on_attach,
})

vim.lsp.config("dartls", {
  capabilities = capabilities,
  on_attach = on_attach,
  cmd = { "dart", "language-server", "--protocol=lsp" },
  filetypes = { "dart" },
  init_options = {
    closingLabels = true,
    flutterOutline = true,
    onlyAnalyzeProjectsWithOpenFiles = true,
    outline = true,
    suggestFromUnimportedLibraries = true,
  },
  settings = {
    dart = {
      completeFunctionCalls = true,
      showTodos = true,
    },
  },
})

vim.lsp.config("html", {
  capabilities = capabilities,
  on_attach = on_attach,
})

vim.lsp.config("csharp_ls", {
  capabilities = capabilities,
  on_attach = on_attach,
  cmd = { "/home/toast/.dotnet/tools/csharp-ls" }
})

vim.lsp.config("jsonls", {
  capabilities = capabilities,
  on_attach = on_attach,
})

vim.lsp.config("htmx", {
  capabilities = capabilities,
  on_attach = on_attach
})

require "autoclose".setup()

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

  -- last 3 items: parent/parent/file
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
        '%=', -- End left alignment
        { hl = 'MiniStatuslineLsp', strings = { lsp() } },
        { hl = mode_hl,             strings = { location } },
      })
    end,
  },
  use_icons = true,
})


require "vim-options"
require "keymaps"
