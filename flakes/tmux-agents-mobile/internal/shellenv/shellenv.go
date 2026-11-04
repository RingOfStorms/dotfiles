// Package shellenv describes the environment boundary for new login shells.
package shellenv

// LoginMarkers are run-once guards exported by NixOS, nix-darwin and Home
// Manager profiles. A service may inherit these while its PATH is replaced by
// systemd's minimal PATH. Clear them so the new shell rebuilds the user PATH.
// Direct PTYs omit them; tmux needs per-spawn empty overrides because an
// already-running server or session can still contain the old values.
var LoginMarkers = [...]string{
	"__NIXOS_SET_ENVIRONMENT_DONE",
	"__ETC_PROFILE_DONE",
	"__NIX_DARWIN_SET_ENVIRONMENT_DONE",
	"__ETC_PROFILE_NIX_SOURCED",
	"__HM_SESS_VARS_SOURCED",
	"__HM_ZSH_SESS_VARS_SOURCED",
}
