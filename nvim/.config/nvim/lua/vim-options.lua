vim.cmd("syntax enable")

vim.g.mapleader = " "

local opt = vim.opt

-- General Editing and Appearence
opt.number = true
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.autoindent = true
opt.smartindent = true
opt.wrap = false
opt.scrolloff = 8
opt.inccommand = "nosplit"
opt.listchars = "tab: "
opt.cursorline = true
opt.winborder = "rounded"
opt.termguicolors = true
opt.list = true
opt.guifont = "Agave Nerd Font Mono 12"
vim.g.db_ui_use_nerd_fonts = 1
vim.cmd("colorscheme vague")

-- Search and Navigation
opt.ignorecase = true
opt.incsearch = true
opt.smartcase = true
opt.path = opt.path + "**"
opt.wildmenu = true

-- File Management
opt.undofile = true
opt.swapfile = false
opt.backup = false

-- Perfomance and Responsiveness
opt.updatetime = 300
opt.timeoutlen = 500

opt.shell = "fish"
opt.clipboard = opt.clipboard + "unnamedplus"
