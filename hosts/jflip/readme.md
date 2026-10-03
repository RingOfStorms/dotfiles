# Install

- termux, termux api, widget, boot, styling

```
pkg install sshd termux-services
pkg install nvim
pkg install starship
pkg install termux-api tergent openssh jq netcat-openbsd

sv-enable sshd
```

# FILES

~/.bashrc

```
alias ls="ls --color -Gah"
alias n="nvim"

eval "$(starship init bash)"
```


~/.ssh/authorized_keys

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDCDxClNxMHqXy3cwj6wGx3r16/fKclgef5LPlt9cqrF 2jflip
```

~/.termux/boot/start-sshd

```
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
. $PREFIX/etc/profile
```

~/.shortcuts/ssh_lio
```
#!/data/data/com.termux/files/usr/bin/sh
ssh -tt lio tat
```

~/.termux/termux.properties (append to the default file, apply with `termux-reload-settings`)

- Arrows are an inverted T (UP above DOWN); both rows have 6 keys so the columns line up.
- ZOOM sends the tmux prefix (Ctrl+Space) then Space to zoom/unzoom a pane. Use `'CTRL SPACE z'` if the Space binding doesn't work.
- KEYBOARD toggles the Android keyboard, since tapping inside tmux with mouse mode on doesn't bring it up.

```
extra-keys = [ \
  ['ESC', 'CTRL', 'UP', 'ALT', 'TAB', {macro: 'CTRL SPACE SPACE', display: 'ZOOM'}], \
  ['/', 'LEFT', 'DOWN', 'RIGHT', 'ENTER', 'KEYBOARD'] \
]
```

# Biometic ssh key

```
termux-keystore generate jflip2lio -a EC -s 256 -u 10
ssh-keygen -D $PREFIX/lib/libtergent.so > jflip2lio.pub
cat jflip2lio.pub
```

May need to create if not present: `scp lio:~/.ssh/jflip2lio jflip:~/.ssh`
~/.ssh/config

```
Host lio
  HostName 100.64.0.1
  User josh
  PKCS11Provider /data/data/com.termux/files/usr/lib/libtergent.so
```
