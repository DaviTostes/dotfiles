vim.pack.add({ "https://github.com/ThePrimeagen/99" })

local _99 = require("99")

local cwd = vim.uv.cwd()
local basename = vim.fs.basename(cwd)

_99.setup({
  model = "anthropic/claude-sonnet-4-5",
  logger = {
    level = _99.DEBUG,
    path = "/tmp/" .. basename .. ".99.debug",
    print_on_error = true,
  },
  md_files = {
    "AGENT.md",
  },
})
