Install
- termux, termux api, widget, boot, styling

```
pkg install sshd
pkg install nvim
pkg install starship
```


~/.bashrc
```
alias ls="ls --color -Gah"
alias n="nvim"

eval "$(starship init bash)"
```

May need to create if not present: `scp lio:~/.ssh/jflip2lio jflip:~/.ssh`
~/.ssh/config
```
Host lio
  HostName 100.64.0.1
  User josh
  IdentityFile ~/.ssh/jflip2lio
```

~/.ssh/authorized_keys
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDCDxClNxMHqXy3cwj6wGx3r16/fKclgef5LPlt9cqrF 2jflip
```
