#!/bin/bash

# Enhanced Language Compiler Installer for Arch Linux
# This script helps you install compilers for various programming languages
# Supports both pacman and yay (AUR helper)

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to display header
display_header() {
  clear
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║                     Language Installer                     ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo
}

# Better user detection for post-installation commands
get_original_user() {
  # Try multiple methods to get the original user
  ORIGINAL_USER=$(logname 2>/dev/null || who am i | awk '{print $1}' || echo "$SUDO_USER")
  
  # Fallback to checking environment variables if the above methods fail
  if [ -z "$ORIGINAL_USER" ] || [ "$ORIGINAL_USER" = "root" ]; then
    for var in SUDO_USER LOGNAME USER; do
      if [ -n "${!var}" ] && [ "${!var}" != "root" ]; then
        ORIGINAL_USER="${!var}"
        break
      fi
    done
  fi
  
  # If still no user found, default to current user
  if [ -z "$ORIGINAL_USER" ] || [ "$ORIGINAL_USER" = "root" ]; then
    ORIGINAL_USER=$(whoami)
  fi
  
  echo "$ORIGINAL_USER"
}

# Fix 4: Improve the check_root function (which was referenced but not shown)
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root when using pacman.${NC}"
    echo -e "${YELLOW}Please run with sudo or as root.${NC}"
    exit 1
  fi
}

# Improved post-installation execution function
run_as_user() {
  local cmd="$1"
  local user=$(get_original_user)
  
  if [ -n "$user" ] && [ "$user" != "root" ] && [ "$user" != "$(whoami)" ]; then
    echo -e "${YELLOW}Running as user $user: $cmd${NC}"
    su - "$user" -c "$cmd" || sudo -u "$user" "$cmd" || echo -e "${RED}Command failed, you may need to run '$cmd' manually${NC}"
  else
    echo -e "${YELLOW}Running: $cmd${NC}"
    eval "$cmd" || echo -e "${RED}Command failed, you may need to run '$cmd' manually${NC}"
  fi
}

# Improved package manager installation with verification
install_and_verify() {
  local pkg="$1"
  local verify_cmd="$2"
  
  echo -e "${YELLOW}Installing $pkg...${NC}"
  install_packages "$pkg"
  
  # Verify installation
  if eval "$verify_cmd" &>/dev/null; then
    echo -e "${GREEN}$pkg installed successfully.${NC}"
    return 0
  else
    echo -e "${RED}$pkg installation could not be verified. You may need to install it manually.${NC}"
    return 1
  fi
}

# Detect package manager (yay or pacman)
detect_package_manager() {
  if command -v yay &> /dev/null; then
    package_manager="yay"
    echo -e "${GREEN}Using yay as package manager.${NC}"
  elif command -v pacman &> /dev/null; then
    package_manager="pacman"
    echo -e "${YELLOW}Using pacman as package manager.${NC}"
    check_root
  else
    echo -e "${RED}Error: Neither yay nor pacman found. This script is designed for Arch Linux or Arch-based distributions.${NC}"
    exit 1
  fi
}

detect_installed_languages() {
  installed_languages=()
  
  for lang in "${!language_compilers[@]}"; do
    local compilers=(${language_compilers[$lang]})
    
    # Check if any compiler for this language is installed
    for compiler in "${compilers[@]}"; do
      if is_package_installed "$compiler"; then
        installed_languages+=("$lang")
        break
      fi
    done
  done
  
  # Sort the installed languages alphabetically
  IFS=$'\n' installed_languages=($(sort <<<"${installed_languages[*]}"))
  unset IFS
}

# Update package database
update_packages() {
  echo -e "${YELLOW}Updating package database...${NC}"
  if [[ "$package_manager" == "yay" ]]; then
    yay -Sy --noconfirm
  else
    pacman -Sy --noconfirm
  fi
  echo -e "${GREEN}Package database updated successfully.${NC}"
  echo
}

# Install packages based on detected package manager
install_packages() {
  local packages=("$@")
  
  if [[ "$package_manager" == "yay" ]]; then
    yay -S --noconfirm "${packages[@]}" || echo -e "${RED}Failed to install some packages${NC}"
  else
    pacman -S --noconfirm "${packages[@]}" || echo -e "${RED}Failed to install some packages${NC}"
  fi
}

# Function to delete languages
delete_language() {
  local language=$1
  
  echo -e "${YELLOW}Removing compiler/interpreter for $language...${NC}"
  
  # Backup configs before deletion
  backup_language_config "$language"
  
  # Get compilers for this language
  local language_compiler_list=(${language_compilers[$language]})
  local packages_to_remove=()
  
  for compiler in "${language_compiler_list[@]}"; do
    if is_package_installed "$compiler"; then
      # Check for dependencies before removing
      if check_removal_dependencies "$compiler"; then
        packages_to_remove+=("$compiler")
      fi
    fi
  done
  
  if [ ${#packages_to_remove[@]} -gt 0 ]; then
    echo -e "${YELLOW}Removing compilers for $language: ${packages_to_remove[*]}${NC}"
    
    if [[ "$package_manager" == "yay" ]]; then
      yay -Rns --noconfirm "${packages_to_remove[@]}" || echo -e "${RED}Failed to remove some packages${NC}"
    else
      pacman -Rns --noconfirm "${packages_to_remove[@]}" || echo -e "${RED}Failed to remove some packages${NC}"
    fi
    
    echo -e "${GREEN}Removed compilers for $language.${NC}"
  else
    echo -e "${YELLOW}No compilers found for $language.${NC}"
  fi
}

# Check if package is installed
is_package_installed() {
  local package=$1
  if [[ "$package_manager" == "yay" ]]; then
    yay -Q "$package" &> /dev/null
  else
    pacman -Q "$package" &> /dev/null
  fi
  return $?
}

# Add dependency tracking for language compilers
declare -A compiler_dependencies

# Core language dependencies
compiler_dependencies["rustup"]="rust"
compiler_dependencies["cargo"]="rust"
compiler_dependencies["truffleruby"]="jdk-openjdk"
compiler_dependencies["jruby"]="jdk-openjdk"
compiler_dependencies["scala"]="jdk-openjdk"
compiler_dependencies["scala3"]="jdk-openjdk"
compiler_dependencies["kotlin"]="jdk-openjdk"
compiler_dependencies["groovy"]="jdk-openjdk"
compiler_dependencies["clojure"]="jdk-openjdk"

# GCC language front-ends
compiler_dependencies["gcc-ada"]="gcc"
compiler_dependencies["gcc-fortran"]="gcc"

# JavaScript ecosystem
compiler_dependencies["ts-node"]="nodejs"
compiler_dependencies["typescript"]="nodejs"

# Build tools and runtime dependencies
compiler_dependencies["stack"]="ghc"
compiler_dependencies["cabal-install"]="ghc"
compiler_dependencies["mix"]="elixir"
compiler_dependencies["hex"]="elixir"
compiler_dependencies["opam"]="ocaml"
compiler_dependencies["nimble"]="nim"
compiler_dependencies["pub"]="dart"
compiler_dependencies["shards"]="crystal"
compiler_dependencies["bundler"]="ruby"
compiler_dependencies["pip"]="python"
compiler_dependencies["pipenv"]="python"
compiler_dependencies["poetry"]="python"
compiler_dependencies["luarocks"]="lua"
compiler_dependencies["maven"]="jdk-openjdk"
compiler_dependencies["gradle"]="jdk-openjdk"
compiler_dependencies["sbt"]="scala"


# Available languages and their compilers
declare -A language_compilers

# System programming languages
language_compilers["c"]="gcc clang tcc pcc"
language_compilers["c++"]="gcc clang"
language_compilers["c3"]="c3c"
language_compilers["rust"]="rust rustup"
language_compilers["go"]="go"
language_compilers["d"]="dmd ldc gdc"
language_compilers["fortran"]="gcc-fortran flang"
language_compilers["ada"]="gcc-ada"
language_compilers["nim"]="nim"
language_compilers["zig"]="zig"
language_compilers["crystal"]="crystal"
language_compilers["v"]="vlang"

# Scripting languages
language_compilers["python"]="python python2 pypy pypy3"
language_compilers["ruby"]="ruby jruby truffleruby"
language_compilers["perl"]="perl rakudo"
language_compilers["php"]="php php56 php70 php71 php72 php73 php74 php80 php81"
language_compilers["lua"]="lua luajit lua51 lua52 lua53"
language_compilers["javascript"]="nodejs deno typescript ts-node"
language_compilers["shell"]="bash zsh fish dash mksh ksh"

# JVM languages
language_compilers["java"]="jdk-openjdk jdk8-openjdk jdk11-openjdk jdk17-openjdk jdk21-openjdk"
language_compilers["kotlin"]="kotlin"
language_compilers["scala"]="scala scala3"
language_compilers["groovy"]="groovy"

# Functional languages
language_compilers["haskell"]="ghc stack"
language_compilers["ocaml"]="ocaml"
language_compilers["erlang"]="erlang"
language_compilers["elixir"]="elixir"
language_compilers["f#"]="fsharp"
language_compilers["lisp"]="sbcl clisp ecl guile racket chicken-scheme chez-scheme mit-scheme clojure"

# Other languages
language_compilers["swift"]="swift"
language_compilers["assembly"]="nasm yasm fasm"
language_compilers["r"]="r"
language_compilers["dart"]="dart"
language_compilers["julia"]="julia"
language_compilers["prolog"]="swi-prolog gnu-prolog"
language_compilers["pascal"]="fpc"
language_compilers["tcl"]="tcl"

# External package managers for languages
declare -A external_package_managers
external_package_managers["rust"]="cargo"
external_package_managers["python"]="pip pipenv poetry"
external_package_managers["javascript"]="npm yarn pnpm"
external_package_managers["go"]="dep"
external_package_managers["ruby"]="gem bundler"
external_package_managers["php"]="composer"
external_package_managers["java"]="maven gradle"
external_package_managers["haskell"]="cabal"
external_package_managers["dart"]="pub"
external_package_managers["r"]="cran"
external_package_managers["lua"]="luarocks"
external_package_managers["julia"]="pkg"
external_package_managers["nim"]="nimble"
external_package_managers["crystal"]="shards"
external_package_managers["perl"]="cpan"
external_package_managers["elixir"]="mix hex"
external_package_managers["swift"]="swift-package-manager"
external_package_managers["kotlin"]="gradle"
external_package_managers["scala"]="sbt"
external_package_managers["ocaml"]="opam"

# Function to prompt for languages
select_languages() {
  display_header
  echo -e "${YELLOW}Available programming languages:${NC}"
  echo
  
  languages=()
  options=()
  
  # Generate options list
  for lang in "${!language_compilers[@]}"; do
    options+=("$lang")
  done
  
  # Sort options alphabetically
  IFS=$'\n' sorted_options=($(sort <<<"${options[*]}"))
  unset IFS
  
  # Display options
  echo -e "  ${GREEN}0.${NC} ${CYAN}Return to Main Menu${NC}"
  echo -e "  ${GREEN}A.${NC} ${CYAN}ALL LANGUAGES${NC}"
  for i in "${!sorted_options[@]}"; do
    echo -e "  ${GREEN}$((i+1)).${NC} ${sorted_options[i]}"
  done
  
  echo
  echo -e "${YELLOW}Enter the numbers of languages you want to install compilers/interpreters for${NC}"
  echo -e "${YELLOW}(separated by spaces), 'A' for all, or '0' to return:${NC}"
  read -r selections
  
  # Process selections
  if [[ "$selections" == "0" ]]; then
    echo -e "${YELLOW}Returning to Main Menu.${NC}"
    return 1  # Return with error to indicate cancellation
  elif [[ "$selections" == "A" || "$selections" == "a" ]]; then
    # All languages selected
    languages=("${sorted_options[@]}")
    echo -e "${GREEN}All languages selected!${NC}"
  else
    # Process individual selections
    for selection in $selections; do
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#sorted_options[@]}" ]; then
        languages+=("${sorted_options[$((selection-1))]}")
      fi
    done
  fi
  
  echo
  if [ ${#languages[@]} -gt 0 ]; then
    echo -e "${GREEN}Selected languages: ${languages[*]}${NC}"
    return 0
  else
    echo -e "${RED}No valid languages selected.${NC}"
    sleep 1
    return 1
  fi
}

# Function to select compilers for a language
select_languages_installers() {
  local language=$1
  local available_compilers=(${language_compilers[$language]})
  local selected_compilers=()
  
  display_header
  echo -e "${YELLOW}Available compilers for $language:${NC}"
  echo
  
  # Display available compilers
  echo -e "  ${GREEN}0.${NC} ${CYAN}Return to Previous Menu${NC}"
  echo -e "  ${GREEN}A.${NC} ${CYAN}ALL COMPILERS${NC}"
  for i in "${!available_compilers[@]}"; do
    echo -e "  ${GREEN}$((i+1)).${NC} ${available_compilers[i]}"
  done
  
  echo
  echo -e "${YELLOW}Enter the numbers of compilers you want to install (separated by spaces),${NC}"
  echo -e "${YELLOW}'A' for all, or '0' to return:${NC}"
  read -r selections
  
  # Process selections
  if [[ "$selections" == "0" ]]; then
    echo -e "${YELLOW}Skipping $language.${NC}"
    sleep 1
    return
  elif [[ "$selections" == "A" || "$selections" == "a" ]]; then
    selected_compilers=("${available_compilers[@]}")
    echo -e "${GREEN}All compilers for $language selected!${NC}"
  else
    for selection in $selections; do
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#available_compilers[@]}" ]; then
        selected_compilers+=("${available_compilers[$((selection-1))]}")
      fi
    done
  fi
  
  echo
  if [ ${#selected_compilers[@]} -gt 0 ]; then
    echo -e "${GREEN}Selected compilers/interpreters for $language: ${selected_compilers[*]}${NC}"
    sleep 1
    
    # Install selected compilers
    echo -e "${YELLOW}Installing compilers for $language...${NC}"
    install_packages "${selected_compilers[@]}"
    echo -e "${GREEN}Installation completed for $language.${NC}"
    
    # Check if external package managers are available for this language
    if [[ -n "${external_package_managers[$language]}" ]]; then
      install_package_managers "$language"
    fi
    
    # Add to installed languages array
    installed_languages+=("$language")
    # Add to installed compilers associative array
    installed_compilers["$language"]="${selected_compilers[*]}"
    
    sleep 1
  else
    echo -e "${YELLOW}No compilers selected for $language. Skipping.${NC}"
    sleep 1
  fi
}

# Function to install external package managers
install_package_managers() {
  local language=$1
  local available_package_managers=(${external_package_managers[$language]})
  local selected_package_managers=()
  
  display_header
  echo -e "${YELLOW}$language has external package managers available:${NC}"
  echo
  
  # Display available package managers
  echo -e "  ${GREEN}0.${NC} ${CYAN}Skip Package Managers${NC}"
  echo -e "  ${GREEN}A.${NC} ${CYAN}ALL PACKAGE MANAGERS${NC}"
  for i in "${!available_package_managers[@]}"; do
    echo -e "  ${GREEN}$((i+1)).${NC} ${available_package_managers[i]}"
  done
  
  echo
  echo -e "${YELLOW}Would you like to install any external package managers for $language?${NC}"
  echo -e "${YELLOW}Enter the numbers (separated by spaces), 'A' for all, or '0' to skip:${NC}"
  read -r selections
  
  # Process selections
  if [[ "$selections" == "0" ]]; then
    echo -e "${YELLOW}Skipping package managers for $language.${NC}"
    return
  elif [[ "$selections" == "A" || "$selections" == "a" ]]; then
    selected_package_managers=("${available_package_managers[@]}")
    echo -e "${GREEN}All package managers for $language selected!${NC}"
  else
    for selection in $selections; do
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#available_package_managers[@]}" ]; then
        selected_package_managers+=("${available_package_managers[$((selection-1))]}")
      fi
    done
  fi
  
  echo
  if [ ${#selected_package_managers[@]} -gt 0 ]; then
    echo -e "${GREEN}Selected package managers for $language: ${selected_package_managers[*]}${NC}"
    sleep 1
    
    # Install selected package managers
    echo -e "${YELLOW}Installing package managers for $language...${NC}"
    
    # For each selected package manager, determine how to install it
    for pkg_mgr in "${selected_package_managers[@]}"; do
      case "$pkg_mgr" in
        "cargo")
          # Cargo is typically installed with rustup
          if is_package_installed "rustup"; then
            echo -e "${GREEN}Cargo will be installed via rustup.${NC}"
          else
            echo -e "${YELLOW}Installing rustup which includes cargo...${NC}"
            install_packages "rustup"
          fi
          ;;
        "pip")
          echo -e "${YELLOW}Installing pip...${NC}"
          install_packages "python-pip"
          ;;
        "pipenv")
          echo -e "${YELLOW}Installing pipenv...${NC}"
          if command -v pip &> /dev/null; then
            pip install --user pipenv
          else
            install_packages "python-pipenv"
          fi
          ;;
        "poetry")
          echo -e "${YELLOW}Installing poetry...${NC}"
          if command -v pip &> /dev/null; then
            pip install --user poetry
          else
            install_packages "python-poetry"
          fi
          ;;
        "npm")
          # npm usually comes with nodejs
          if is_package_installed "nodejs"; then
            echo -e "${GREEN}npm is typically installed with nodejs.${NC}"
          else
            echo -e "${YELLOW}Installing npm...${NC}"
            install_packages "npm"
          fi
          ;;
        "yarn")
          echo -e "${YELLOW}Installing yarn...${NC}"
          install_packages "yarn"
          ;;
        "pnpm")
          echo -e "${YELLOW}Installing pnpm...${NC}"
          if command -v npm &> /dev/null; then
            npm install -g pnpm
          else
            install_packages "pnpm"
          fi
          ;;
        "dep")
          echo -e "${YELLOW}Installing go dep...${NC}"
          install_packages "dep"
          ;;
        "gem")
          # gem typically comes with ruby
          if is_package_installed "ruby"; then
            echo -e "${GREEN}gem is typically installed with ruby.${NC}"
          else
            echo -e "${YELLOW}Installing ruby which includes gem...${NC}"
            install_packages "ruby"
          fi
          ;;
        "bundler")
          echo -e "${YELLOW}Installing bundler...${NC}"
          if command -v gem &> /dev/null; then
            gem install bundler
          else
            install_packages "ruby-bundler"
          fi
          ;;
        "composer")
          echo -e "${YELLOW}Installing composer...${NC}"
          install_packages "composer"
          ;;
        "maven")
          echo -e "${YELLOW}Installing maven...${NC}"
          install_packages "maven"
          ;;
        "gradle")
          echo -e "${YELLOW}Installing gradle...${NC}"
          install_packages "gradle"
          ;;
        "cabal")
          # cabal often comes with ghc
          if is_package_installed "ghc"; then
            echo -e "${GREEN}cabal is typically installed with ghc.${NC}"
          else
            echo -e "${YELLOW}Installing cabal...${NC}"
            install_packages "cabal-install"
          fi
          ;;
        "pub")
          # pub comes with dart
          if is_package_installed "dart"; then
            echo -e "${GREEN}pub is included with dart.${NC}"
          else
            echo -e "${YELLOW}Installing dart which includes pub...${NC}"
            install_packages "dart"
          fi
          ;;
        "cran")
          # R package installer
          if is_package_installed "r"; then
            echo -e "${GREEN}CRAN functionality is included with R.${NC}"
          else
            echo -e "${YELLOW}Installing R which includes CRAN functionality...${NC}"
            install_packages "r"
          fi
          ;;
        "luarocks")
          echo -e "${YELLOW}Installing luarocks...${NC}"
          install_packages "luarocks"
          ;;
        "pkg")
          # Julia package manager
          if is_package_installed "julia"; then
            echo -e "${GREEN}Pkg is included with Julia.${NC}"
          else
            echo -e "${YELLOW}Installing julia which includes Pkg...${NC}"
            install_packages "julia"
          fi
          ;;
        "nimble")
          # Nim package manager
          if is_package_installed "nim"; then
            echo -e "${GREEN}Nimble is typically installed with Nim.${NC}"
          else
            echo -e "${YELLOW}Installing nim which includes nimble...${NC}"
            install_packages "nim"
          fi
          ;;
        "shards")
          # Crystal package manager
          if is_package_installed "crystal"; then
            echo -e "${GREEN}Shards is typically installed with Crystal.${NC}"
          else
            echo -e "${YELLOW}Installing crystal which includes shards...${NC}"
            install_packages "crystal"
          fi
          ;;
        "cpan")
          # Perl package manager
          if is_package_installed "perl"; then
            echo -e "${GREEN}CPAN is included with Perl.${NC}"
          else
            echo -e "${YELLOW}Installing perl which includes CPAN...${NC}"
            install_packages "perl"
          fi
          ;;
        "mix")
          # Elixir build tool
          if is_package_installed "elixir"; then
            echo -e "${GREEN}Mix is included with Elixir.${NC}"
          else
            echo -e "${YELLOW}Installing elixir which includes Mix...${NC}"
            install_packages "elixir"
          fi
          ;;
        "hex")
          # Elixir package manager
          if command -v mix &> /dev/null; then
            echo -e "${GREEN}Hex can be installed via Mix.${NC}"
            mix local.hex --force
          else
            echo -e "${YELLOW}Installing elixir first which includes Mix for Hex installation...${NC}"
            install_packages "elixir"
            mix local.hex --force
          fi
          ;;
        "swift-package-manager")
          # Swift package manager
          if is_package_installed "swift"; then
            echo -e "${GREEN}Swift Package Manager is included with Swift.${NC}"
          else
            echo -e "${YELLOW}Installing swift which includes Swift Package Manager...${NC}"
            install_packages "swift"
          fi
          ;;
        "sbt")
          echo -e "${YELLOW}Installing sbt...${NC}"
          install_packages "sbt"
          ;;
        "opam")
          echo -e "${YELLOW}Installing opam...${NC}"
          install_packages "opam"
          ;;
        *)
          echo -e "${RED}Unknown package manager: $pkg_mgr${NC}"
          ;;
      esac
    done
    
    echo -e "${GREEN}Package managers installation completed for $language.${NC}"
    
    # Add to installed package managers associative array
    installed_package_managers["$language"]="${selected_package_managers[*]}"
    
    sleep 1
  else
    echo -e "${YELLOW}No package managers selected for $language. Skipping.${NC}"
    sleep 1
  fi
}

backup_config_dir() {
  local dir="$1"
  local backup_dir="$2"
  
  if [ -d "$dir" ]; then
    mkdir -p "$backup_dir" 2>/dev/null
    cp -r "$dir" "$backup_dir/" 2>/dev/null
    return 0
  fi
  return 1
}

# Function to backup configurations before removal
backup_language_config() {
  local language="$1"
  local backup_dir="$HOME/.language_installer_backups/$language-$(date +%Y%m%d%H%M%S)"
  
  echo -e "${YELLOW}Creating backup of $language configurations...${NC}"
  mkdir -p "$backup_dir"
  
  case "$language" in
    "rust")
      if [ -d "$HOME/.cargo" ]; then
        cp -r "$HOME/.cargo/config.toml" "$backup_dir/" 2>/dev/null
      fi
      if [ -d "$HOME/.rustup" ]; then
        cp -r "$HOME/.rustup/settings.toml" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "python")
      if [ -f "$HOME/.pip/pip.conf" ]; then
        cp "$HOME/.pip/pip.conf" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.config/pip/pip.conf" ]; then
        cp "$HOME/.config/pip/pip.conf" "$backup_dir/" 2>/dev/null
      fi
      if [ -d "$HOME/.venv" ]; then
        cp -r "$HOME/.venv" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.pypirc" ]; then
        cp "$HOME/.pypirc" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "javascript")
      if [ -f "$HOME/.npmrc" ]; then
        cp "$HOME/.npmrc" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.yarnrc" ]; then
        cp "$HOME/.yarnrc" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.pnpmrc" ]; then
        cp "$HOME/.pnpmrc" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "ruby")
      if [ -f "$HOME/.gemrc" ]; then
        cp "$HOME/.gemrc" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.bundle/config" ]; then
        cp "$HOME/.bundle/config" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "java")
      if [ -f "$HOME/.gradle/gradle.properties" ]; then
        cp "$HOME/.gradle/gradle.properties" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.m2/settings.xml" ]; then
        cp "$HOME/.m2/settings.xml" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "go")
      if [ -f "$HOME/.config/go/env" ]; then
        cp "$HOME/.config/go/env" "$backup_dir/" 2>/dev/null
      fi
      if [ -d "$HOME/go/src" ]; then
        # Just backup the directory structure, not all files
        find "$HOME/go/src" -type d -exec mkdir -p "$backup_dir/go_structure/{}" \; 2>/dev/null
      fi
      ;;
    "haskell")
      if [ -f "$HOME/.cabal/config" ]; then
        cp "$HOME/.cabal/config" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.stack/config.yaml" ]; then
        cp "$HOME/.stack/config.yaml" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "elixir")
      if [ -f "$HOME/.mix/config.exs" ]; then
        cp "$HOME/.mix/config.exs" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.hex/hex.config" ]; then
        cp "$HOME/.hex/hex.config" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "ocaml")
      if [ -f "$HOME/.opam/config" ]; then
        cp "$HOME/.opam/config" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "php")
      if [ -f "$HOME/.composer/composer.json" ]; then
        cp "$HOME/.composer/composer.json" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.composer/auth.json" ]; then
        cp "$HOME/.composer/auth.json" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "lua")
      if [ -f "$HOME/.luarocks/config.lua" ]; then
        cp "$HOME/.luarocks/config.lua" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "r")
      if [ -f "$HOME/.Rprofile" ]; then
        cp "$HOME/.Rprofile" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.Renviron" ]; then
        cp "$HOME/.Renviron" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "dart")
      if [ -f "$HOME/.pub-cache/credentials.json" ]; then
        cp "$HOME/.pub-cache/credentials.json" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "julia")
      if [ -f "$HOME/.julia/config/startup.jl" ]; then
        cp "$HOME/.julia/config/startup.jl" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "nim")
      if [ -f "$HOME/.config/nim/nim.cfg" ]; then
        cp "$HOME/.config/nim/nim.cfg" "$backup_dir/" 2>/dev/null
      fi
      if [ -f "$HOME/.nimble/nimble.ini" ]; then
        cp "$HOME/.nimble/nimble.ini" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "scala")
      if [ -f "$HOME/.sbt/1.0/global.sbt" ]; then
        cp "$HOME/.sbt/1.0/global.sbt" "$backup_dir/" 2>/dev/null
      fi
      ;;
    "perl")
      if [ -f "$HOME/.cpan/CPAN/MyConfig.pm" ]; then
        cp "$HOME/.cpan/CPAN/MyConfig.pm" "$backup_dir/" 2>/dev/null
      fi
      ;;
    *)
      echo -e "${YELLOW}No specific configuration files known for $language${NC}"
      ;;
  esac
  
  echo -e "${GREEN}Backup created at $backup_dir${NC}"
}

check_removal_dependencies() {
  local package="$1"
  local dependent_packages=()
  
  # Check if this package is a dependency for other installed compilers
  for dep in "${!compiler_dependencies[@]}"; do
    if [ "${compiler_dependencies[$dep]}" = "$package" ] && is_package_installed "$dep"; then
      dependent_packages+=("$dep")
    fi
  done
  
  if [ ${#dependent_packages[@]} -gt 0 ]; then
    echo -e "${RED}Warning: Removing $package may affect these installed packages: ${dependent_packages[*]}${NC}"
    echo -e "${YELLOW}Do you want to continue? (y/n)${NC}"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      return 1
    fi
  fi
  
  return 0
}

# Function to delete language
delete_languages() {
  display_header
  
  # Detect currently installed languages
  detect_installed_languages
  
  if [ ${#installed_languages[@]} -eq 0 ]; then
    echo -e "${YELLOW}No programming languages detected on the system.${NC}"
    echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
    read -r
    return
  fi
  
  echo -e "${YELLOW}Installed programming languages:${NC}"
  echo
  
  # Display options
  echo -e "  ${GREEN}0.${NC} ${CYAN}Return to Main Menu${NC}"
  echo -e "  ${GREEN}A.${NC} ${CYAN}ALL LANGUAGES${NC}"
  for i in "${!installed_languages[@]}"; do
    echo -e "  ${GREEN}$((i+1)).${NC} ${installed_languages[i]}"
  done
  
  echo
  echo -e "${YELLOW}Enter the numbers of languages you want to remove${NC}"
  echo -e "${YELLOW}(separated by spaces), 'A' for all, or '0' to return:${NC}"
  read -r selections
  
  # Process selections
  if [[ "$selections" == "0" ]]; then
    return
  fi
  
  # Languages to remove
  local languages_to_remove=()
  
  if [[ "$selections" == "A" || "$selections" == "a" ]]; then
    languages_to_remove=("${installed_languages[@]}")
    echo -e "${YELLOW}All installed languages selected for removal.${NC}"
  else
    # Process individual selections
    for selection in $selections; do
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#installed_languages[@]}" ]; then
        languages_to_remove+=("${installed_languages[$((selection-1))]}")
      fi
    done
  fi
  
  echo
  if [ ${#languages_to_remove[@]} -gt 0 ]; then
    echo -e "${YELLOW}The following languages will be removed: ${languages_to_remove[*]}${NC}"
    echo -e "${RED}Warning: This will remove all compilers/interpreters and related tools for these languages.${NC}"
    echo -e "${YELLOW}Are you sure you want to continue? (y/n)${NC}"
    read -r confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
      for lang in "${languages_to_remove[@]}"; do
        delete_language "$lang"
        delete_languages_package_managers "$lang"
      done
      echo -e "${GREEN}Language removal completed.${NC}"
    else
      echo -e "${YELLOW}Language removal cancelled.${NC}"
    fi
  else
    echo -e "${RED}No valid languages selected for removal.${NC}"
  fi
  
  sleep 1
}

# Function to remove package managers for a language
delete_languages_package_managers() {
  local language=$1
  
  # Check if there are package managers for this language
  if [[ -z "${external_package_managers[$language]}" ]]; then
    return
  fi
  
  local pkg_managers=(${external_package_managers[$language]})
  local packages_to_remove=()
  
  echo -e "${YELLOW}Checking installed package managers for $language...${NC}"
  
  # Check which package managers are installed
  for pkg_mgr in "${pkg_managers[@]}"; do
    # For language-specific package managers, we need different checks
    case "$pkg_mgr" in
      "cargo")
        # We don't remove cargo separately as it's part of rust
        continue
        ;;
      "pip")
        if is_package_installed "python-pip"; then
          packages_to_remove+=("python-pip")
        fi
        ;;
      "pipenv")
        if is_package_installed "python-pipenv"; then
          packages_to_remove+=("python-pipenv")
        fi
        ;;
      "poetry")
        if is_package_installed "python-poetry"; then
          packages_to_remove+=("python-poetry")
        fi
        ;;
      "npm")
        if is_package_installed "npm"; then
          packages_to_remove+=("npm")
        fi
        ;;
      *)
        if is_package_installed "$pkg_mgr"; then
          packages_to_remove+=("$pkg_mgr")
        fi
        ;;
    esac
  done
  
  if [ ${#packages_to_remove[@]} -gt 0 ]; then
    echo -e "${YELLOW}Removing package managers for $language: ${packages_to_remove[*]}${NC}"
    
    if [[ "$package_manager" == "yay" ]]; then
      yay -Rns --noconfirm "${packages_to_remove[@]}" || echo -e "${RED}Failed to remove some packages${NC}"
    else
      pacman -Rns --noconfirm "${packages_to_remove[@]}" || echo -e "${RED}Failed to remove some packages${NC}"
    fi
    
    echo -e "${GREEN}Removed package managers for $language.${NC}"
  else
    echo -e "${YELLOW}No package managers found for $language.${NC}"
  fi
}

# Function to configure after installation
post_install_config() {
  display_header
  echo -e "${YELLOW}Performing post-installation configuration...${NC}"
  
  # Check for installed languages and perform any necessary post-install steps
  for lang in "${installed_languages[@]}"; do
    case $lang in
      "rust")
        if command -v rustup &> /dev/null; then
          echo -e "${YELLOW}Configuring Rust...${NC}"
          # Run rustup as the original user, not as root
          if [[ "$package_manager" == "pacman" ]]; then
            ORIGINAL_USER=$(logname 2>/dev/null || who am i | awk '{print $1}')
            if [ -n "$ORIGINAL_USER" ]; then
              su - "$ORIGINAL_USER" -c "rustup default stable"
            else
              echo -e "${RED}Could not determine original user. Please run 'rustup default stable' manually.${NC}"
            fi
          else
            rustup default stable
          fi
        fi
        ;;
      "java")
        if command -v archlinux-java &> /dev/null; then
          echo -e "${YELLOW}Configuring Java...${NC}"
          archlinux-java fix
        fi
        ;;
      "haskell")
        if command -v stack &> /dev/null; then
          echo -e "${YELLOW}Configuring Haskell Stack...${NC}"
          if [[ "$package_manager" == "pacman" ]]; then
            ORIGINAL_USER=$(logname 2>/dev/null || who am i | awk '{print $1}')
            if [ -n "$ORIGINAL_USER" ]; then
              su - "$ORIGINAL_USER" -c "stack setup"
            else
              echo -e "${RED}Could not determine original user. Please run 'stack setup' manually.${NC}"
            fi
          else
            stack setup
          fi
        fi
        ;;
      "ruby")
        if command -v gem &> /dev/null; then
          echo -e "${YELLOW}Updating RubyGems...${NC}"
          gem update --system
        fi
        ;;
      "dart")
        if command -v dart &> /dev/null; then
          echo -e "${YELLOW}Configuring Dart...${NC}"
          dart pub get
        fi
        ;;
      "python")
        if command -v pip &> /dev/null; then
          echo -e "${YELLOW}Updating pip...${NC}"
          pip install --upgrade pip
        fi
        ;;
      "ocaml")
        if command -v opam &> /dev/null; then
          echo -e "${YELLOW}Initializing OPAM...${NC}"
          if [[ "$package_manager" == "pacman" ]]; then
            ORIGINAL_USER=$(logname 2>/dev/null || who am i | awk '{print $1}')
            if [ -n "$ORIGINAL_USER" ]; then
              su - "$ORIGINAL_USER" -c "opam init --auto-setup"
            else
              echo -e "${RED}Could not determine original user. Please run 'opam init --auto-setup' manually.${NC}"
            fi
          else
            opam init --auto-setup
          fi
        fi
        ;;
      "elixir")
        if command -v mix &> /dev/null && command -v hex &> /dev/null; then
          echo -e "${YELLOW}Updating Hex...${NC}"
          mix local.hex --force
        fi
        ;;
    esac
  done
  
  echo -e "${GREEN}Post-installation configuration completed.${NC}"
  sleep 1
}

# Function to display summary
display_summary() {
  display_header
  echo -e "${GREEN}Installation Summary:${NC}"
  echo
  
  for lang in "${installed_languages[@]}"; do
    echo -e "${YELLOW}$lang:${NC}"
    
    # Display compilers
    echo -e "${CYAN}  Compilers:${NC}"
    for compiler in ${language_compilers[$lang]}; do
      if is_package_installed "$compiler"; then
        echo -e "    - $compiler: ${GREEN}Installed${NC}"
      else
        echo -e "    - $compiler: ${RED}Not installed${NC}"
      fi
    done
    
    # Display package managers if any were installed
    if [[ -n "${installed_package_managers[$lang]}" ]]; then
      echo -e "${CYAN}  Package Managers:${NC}"
      for pkg_mgr in ${installed_package_managers[$lang]}; do
        # For package managers that are typically part of a language installation or 
        # installed via another tool, we check differently
        case "$pkg_mgr" in
          "cargo")
            if command -v cargo &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
          "pip"|"pipenv"|"poetry")
            if command -v "$pkg_mgr" &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
          "npm"|"yarn"|"pnpm")
            if command -v "$pkg_mgr" &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
          "gem"|"bundler")
            if command -v "$pkg_mgr" &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
          "cabal")
            if command -v cabal &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
          "luarocks")
            if command -v luarocks &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
          *)
            if command -v "$pkg_mgr" &> /dev/null; then
              echo -e "    - $pkg_mgr: ${GREEN}Installed${NC}"
            else
              echo -e "    - $pkg_mgr: ${RED}Not installed${NC}"
            fi
            ;;
        esac
      done
    fi
    
    echo
  done
  
  echo -e "${BLUE}Thank you for using the Ultimate Language Installer!${NC}"
}

# Modify this function to include a main menu with install/delete options
main_menu() {
  while true; do
    display_header
    echo -e "${YELLOW}Main Menu:${NC}"
    echo
    echo -e "  ${GREEN}1.${NC} Install Languages"
    echo -e "  ${GREEN}2.${NC} Delete Languages"
    echo -e "  ${GREEN}0.${NC} Exit"
    echo
    echo -e "${YELLOW}Enter your choice:${NC}"
    read -r choice
    
    case $choice in
      1)
        # Install languages flow
        update_packages
        select_languages
        
        if [ ${#languages[@]} -gt 0 ]; then
          for lang in "${languages[@]}"; do
            select_languages_installers "$lang"
          done
          
          if [ ${#installed_languages[@]} -gt 0 ]; then
            post_install_config
            display_summary
            
            echo
            echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
            read -r
          fi
        fi
        ;;
      2)
        # Delete languages flow
        delete_languages
        ;;
      0)
        echo -e "${GREEN}Thank you for using the Ultimate Language Installer!${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option. Press Enter to try again.${NC}"
        read -r
        ;;
    esac
  done
}

# Modified main execution section
# Replace the existing main execution with this:
display_header
echo -e "${YELLOW}Welcome to the Ultimate Language Installer for Arch Linux${NC}"
echo -e "This script helps you install or remove compilers for various programming languages."
echo -e "It supports both pacman and yay (AUR helper)."
echo
echo -e "${YELLOW}Press Enter to continue...${NC}"
read -r

# Detect package manager
detect_package_manager

# Initialize arrays for tracking
installed_languages=()
declare -A installed_compilers
declare -A installed_package_managers

# Launch main menu
main_menu