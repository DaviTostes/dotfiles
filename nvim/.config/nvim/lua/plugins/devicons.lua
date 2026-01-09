vim.pack.add({"https://github.com/nvim-tree/nvim-web-devicons"})

require("nvim-web-devicons").setup {
    override = {
        zsh = {
            icon = "",
            color = "#428850",
            cterm_color = "65",
            name = "Zsh"
        }
    };
    default = true;
}
