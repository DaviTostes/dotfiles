vim.pack.add(
  {
    { src = "https://github.com/vague2k/vague.nvim" },
    { src = "https://github.com/m4xshen/autoclose.nvim" },
    { src = "https://github.com/kristijanhusak/vim-dadbod-ui" },
    { src = "https://github.com/tpope/vim-dadbod" },
    { src = "https://github.com/kristijanhusak/vim-dadbod-completion" },
    { src = "https://github.com/nvim-telescope/telescope.nvim" },
    { src = "https://github.com/nvim-lua/plenary.nvim" },
    { src = "https://github.com/nvim-telescope/telescope-ui-select.nvim" },
    { src = "https://github.com/ThePrimeagen/harpoon",                   version = "harpoon2" },
    { src = "https://github.com/nvim-lualine/lualine.nvim" },
    { src = "https://github.com/echasnovski/mini.icons" },
    { src = "https://github.com/stevearc/oil.nvim" },
    { src = "https://github.com/christoomey/vim-tmux-navigator" },
    { src = "https://github.com/tribela/transparent.nvim" },
    { src = "https://github.com/nvim-treesitter/nvim-treesitter" },
    { src = "https://github.com/mg979/vim-visual-multi" },
    { src = "https://github.com/neovim/nvim-lspconfig" },
    { src = "https://github.com/hrsh7th/nvim-cmp" },
    { src = "https://github.com/hrsh7th/cmp-nvim-lsp" },
    { src = "https://github.com/L3MON4D3/LuaSnip" },
    { src = "https://github.com/saadparwaiz1/cmp_luasnip" },
    { src = "https://github.com/rafamadriz/friendly-snippets" },
    { src = "https://github.com/nvim-mini/mini.pick" }
  }
)

local builtin = require "telescope.builtin"
vim.keymap.set('n', '<C-p>', function()
  builtin.find_files({ hidden = true })
end, {})

local telescope = require "telescope"
telescope.setup({
  extensions = {
    ['ui-select'] = {
      require "telescope.themes".get_dropdown {}
    }
  }
})
telescope.load_extension('ui-select')

require "lualine".setup({
  options = {
    theme = require("theme"),
    component_separators = '',
    section_separators = '',
    sections = {
      lualine_a = {},
      lualine_b = {},
      lualine_c = { 'mode' }, -- center section shows mode
      lualine_x = {},
      lualine_y = {},
      lualine_z = {},
    },
    inactive_sections = {
      lualine_a = {},
      lualine_b = {},
      lualine_c = { 'filename' }, -- show filename when inactive
      lualine_x = {},
      lualine_y = {},
      lualine_z = {},
    },
  },
  sections = {
    lualine_a = { "mode" },

    lualine_b = {
      "branch",
      "diff",
      "diagnostics",
    },

    lualine_c = {
      {
        "filename",
        path = 1, -- 0 = filename, 1 = relative path, 2 = absolute path
        symbols = {
          modified = " [+]",
          readonly = " 🔒",
          unnamed = "[No Name]",
        },
      },
      {
        function()
          local reg = vim.fn.reg_recording()
          return reg ~= "" and "Recording @" .. reg or ""
        end,
        color = { fg = "#ff9e64", gui = "bold" },
      },
    },

    lualine_x = {
      {
        function()
          local clients = vim.lsp.get_clients({ bufnr = 0 })
          if #clients == 0 then
            return ""
          end
          local names = {}
          for _, client in ipairs(clients) do
            table.insert(names, client.name)
          end
          return " " .. table.concat(names, ", ")
        end,
      },
      -- {
      -- 	function()
      -- 		return "spaces: " .. vim.bo.shiftwidth
      -- 	end,
      -- 	icon = "⎵",
      -- },
      "filetype",
    },

    lualine_y = {
      "progress",
    },

    lualine_z = {
      {
        function()
          return os.date("%H:%M")
        end,
        icon = "",
      },
      "location",
    },
  },
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
  keymaps = {
    ["g?"] = { "actions.show_help", mode = "n" },
    ["<CR>"] = "actions.select",
    ["<C-s>"] = { "actions.select", opts = { vertical = true } },
    ["<C-h>"] = { "actions.select", opts = { horizontal = true } },
    ["<C-t>"] = { "actions.select", opts = { tab = true } },
    ["<C-p>"] = "actions.preview",
    ["<C-c>"] = { "actions.close", mode = "n" },
    ["<C-l>"] = "actions.refresh",
    ["-"] = { "actions.parent", mode = "n" },
    ["_"] = { "actions.open_cwd", mode = "n" },
    ["`"] = { "actions.cd", mode = "n" },
    ["~"] = { "actions.cd", opts = { scope = "tab" }, mode = "n" },
    ["gs"] = { "actions.change_sort", mode = "n" },
    ["gx"] = "actions.open_external",
    ["g."] = { "actions.toggle_hidden", mode = "n" },
    ["g\\"] = { "actions.toggle_trash", mode = "n" },
  }
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
    "regex"
  },
  auto_install = true,
  highlight = { enable = true },
  indent = { enable = true },
})

local on_attach = function(client, bufnr)
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

vim.lsp.enable({ "ts_ls", "pyright", "lua_ls", "gopls", "dartls", "html", "csharp_ls", "jsonls", "cssls" })

vim.lsp.config("ts_ls", {
  capabilities = capabilities,
  on_attach = on_attach,
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
        version = "LuaJIT",
      },
      diagnostics = {
        globals = { "vim" },
      },
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

vim.lsp.config("cssls", {
  capabilities = capabilities,
  on_attach = on_attach,
})

require "autoclose".setup()

require "mini.pick".setup({
  mappings = {
    move_down = '<C-j>',
    move_up = '<C-k>',
  }
})

require "vim-options"
require "keymaps"
