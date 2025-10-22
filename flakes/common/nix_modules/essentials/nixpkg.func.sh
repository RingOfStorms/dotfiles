# nix
alias nixpkgs=nixpkg
nixpkg () {
  if [ $# -eq 0 ]; then
    echo "Error: No arguments provided. Please specify at least one package."
    return 1
  fi
  cmd="nix shell"
  for pkg in "$@"; do
    cmd="$cmd \"nixpkgs#$pkg\""
  done
  eval $cmd
}
