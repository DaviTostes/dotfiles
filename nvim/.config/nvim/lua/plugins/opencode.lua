vim.opt.rtp:prepend("/home/toast/opencode-nvim")

require("opencode-nvim").setup({
  server = { command = "opencode2", autostart = true },
  agent = "build",           -- agente padrão
  approval = false,
  -- approval = {
  --   review = "popup",        -- "popup" | "notify"
  --   agent = "opencode-nvim", -- agente de pré-aprovação
  --   auto_detect = true,      -- usa qualquer agente que peça aprovação
  -- },
  reload = { enabled = true, set_autoread = true },
  context = { auto = true, max_bytes = 200 * 1024 },
  ui = {
    panel = {
      width = 0.45,
      height = 0.50,
      max_width = 110,
      max_height = 50,
      tool_output = false
    },
    focus_after_submit = "panel",
  },
})
