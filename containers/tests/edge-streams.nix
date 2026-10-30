# nix eval --impure --expr 'import ./containers/tests/edge-streams.nix'
let ports = (import ../lib.nix).edgeStreamPorts ../.;
in assert ports == [ 3032 ]; ports
