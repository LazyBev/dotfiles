#!/bin/bash

wipes -a /dev/nvme0n1 && cd ~ && rm -rf dotfiles && git clone https://github.com/LazyBev/dotfiles && cd dotfiles/installer && chmod +x gentoo-install.sh && ./gentoo-install.sh --config gentoo-install.conf