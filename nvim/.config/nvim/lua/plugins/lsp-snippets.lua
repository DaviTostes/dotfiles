vim.pack.add({
  { src = "https://github.com/neovim/nvim-lspconfig" },
  -- snippets
  { src = "https://github.com/hrsh7th/nvim-cmp" },
  { src = "https://github.com/hrsh7th/cmp-nvim-lsp" },
  { src = "https://github.com/L3MON4D3/LuaSnip" },
  { src = "https://github.com/saadparwaiz1/cmp_luasnip" },
  { src = "https://github.com/rafamadriz/friendly-snippets" },
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
  "basedpyright",
  "lua_ls",
  "gopls",
  "dartls",
  "html",
  "omnisharp",
  "jsonls",
  "cssls",
  "htmx",
  "bruno_ls"
})

vim.lsp.config("bruno_ls", {
  cmd = { 'node', '/home/toast/bruno-language-server/out/server.js', '--stdio' },
  filetypes = { 'bru' },
  capabilities = capabilities,
  on_attach = on_attach,
})

vim.lsp.config("ts_ls", {
  capabilities = capabilities,
  on_attach = on_attach,
  init_options = {
    maxTsServerMemory = 512,
    preferences = {
      includeInlayParameterNameHints = "all",
      includeInlayPropertyDeclarationTypeHints = true,
      includeInlayFunctionLikeReturnTypeHints = true,
    },
  },
  settings = {
    typescript = {
      inlayHints = {
        includeInlayParameterNameHints = "all",
      },
    },
  },
})

vim.lsp.config("basedpyright", {
  capabilities = capabilities,
  on_attach = on_attach,
  settings = {
    basedpyright = {
      analysis = {
        typeCheckingMode = "basic",
      },
    },
  },
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
  settings = {
    gopls = {
      semanticTokens = true,
      analyses = {
        unusedparams = true,
      },
    },
  },
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

vim.lsp.config("omnisharp", {
  capabilities = capabilities,
  on_attach = on_attach,
  cmd = {
    "env", "DOTNET_ROOT=/usr/share/dotnet",
    "/usr/bin/omnisharp",
    "--languageserver",
    "--hostPID", tostring(vim.fn.getpid()),
  },
  filetypes = { "cs" },
})

vim.lsp.config("jsonls", {
  capabilities = capabilities,
  on_attach = on_attach,
})

vim.lsp.config("htmx", {
  capabilities = capabilities,
  on_attach = on_attach
})
