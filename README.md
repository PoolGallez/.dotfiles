# Dotfiles
Repo containing my dotfiles.

This is a starting point, hopefully i will extend it when i am ready with polybar, rofi, etc... 
## Dependencies
* Text editor: neovim -> nvim 
	* Plugin manager: vim-plug.  
	* Code completion engine: Youcompleteme. 
* Window manager: BSPWM (Binary Space Partitioning Window Manager) the rounded corner edition  (on the AUR)
* Shortcut deamon: SXHKD (Simple X HotKey Deamon) -> still on Xorg :(
* To set the background: feh 
* Menu launcher: rofi 
* Compositor: picom standard
* Terminal emulator: Alacritty 
* Shell: Zsh

## Instructions 
    
### NeoVim
You can install neovim using the package from the arch repositories and install also the package python-pynvim to have the compatibility with the plugin Youcompleteme for the autocompletion engine. 
``` 
$ pacman -S neovim python-pynvim
```
then create a folder `~/.config/nvim` and put the int.vim configuration file of this repo.

To enable plugins, install vim-plug according to its installation guide for neovim: 
```
$ sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
```
create `~/.config/nvim/plugged`, open a neovim window and run :PlugInstall to install the plugins. 

Then to have the Youcompleteme plugin working correctly, please navigate to `~/.config/nvim/plugged/youcompleteme` and run the `install.py` script. 

### Installation and configuration of Zsh
Zsh is a shell different from bash that has some additional features like syntax-highighting, completion based on history and some more powerful theming.

To install zsh follow the instructions in the Arch wiki, particularly install: 
* Zsh (of course) `$ pacman -S zsh` 
* The autocompletion and syntax highlighting themes: `$ pacman -S zsh-completion zsh-autosuggestions zsh-syntax-highlighting`
* The theme in use (powerlevel10k): `$ pacman -S zsh-theme-powerlevel10k`

Then simply copy .zshrc and .p10k.zsh into the home folder. 

Please recall that you should set zsh as the user's default shell: 
``` 
chsh -s /usr/bin/zsh
```
#### Note about the theme
The theme in use needs some fonts to be used and set in the terminal, in particular it requires the nerd fonts: `sudo pacman -S ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono` 

#### How does zsh look like? 
In this image you can see how code completion and syntax highlighting works in zsh with the above configuration as well as have an idea of how the shell should look like. 
![Zsh highlight completion](https://github.com/PoolGallez/.dotfiles/blob/main/images/zsh_high_compl.png?raw=true "Zsh syntax highlighting and completion")

Here you can see how the theme adapts in the case that your working directory is a git repository with some not-committed changes
![Zsh not commited repo changes](https://github.com/PoolGallez/.dotfiles/blob/main/images/zsh_staged_notComm.png?raw=true "Zsh changes not committed yet")

Here you can see how the theme adapts in the case taht your working directory is a git repository with some committed but not pushed changes
![Zsh changes not pushed](https://github.com/PoolGallez/.dotfiles/blob/main/images/zsh_commt_notPush.png?raw=true "Zsh changes not pushed yet")
