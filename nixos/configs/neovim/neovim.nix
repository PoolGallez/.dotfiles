{config, lib, pkgs, ... } : 

{
  programs.neovim.enable  = true;

  programs.neovim.plugins = with pkgs.vimPlugins; [
     vim-fugitive 
     nerdtree
     vim-airline
     vim-multiple-cursors
     vim-indent-guides
     nord-vim
  ];

  programs.neovim.defaultEditor = true;

  programs.neovim.extraConfig = 
     ''
         " Colorscheme setting 
         colorscheme nord
          "
          " Personal settings for nvim 
          "
          
          " Line numbers are both absolute and relative line numbers to easily move
          " within the code
          set number
          set relativenumber

          " Indentation automatic and based on the type of the file
          set autoindent
          filetype indent on 

          " Highlight the terms you are searching non case sensitive
          set hlsearch
          set incsearch
          set smartcase
          set showmatch

          syntax enable
          set title
          set foldmethod=indent
          set foldnestmax=3
          set nofoldenable

          set cursorline
          set cursorcolumn
          set showmode
          " Enable feature similar to bash completion
          set wildmenu
          set wildmode=list:longest
          set wildignore=*.docx,*.jpg,*.png,*.gif,*.pdf,*.pyc,*.exe,*.flv,*.img,*.xlsx

     '';
}
