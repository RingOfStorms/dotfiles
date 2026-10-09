package main

// Data transfer helpers. Every remote pipeline runs with pipefail so a failure
// on the left of a pipe (tar missing files, unreadable dirs) is not hidden by
// the exit status of the last command. Callers treat any error as "nothing was
// transferred": backups are written to a temp file and only renamed when
// complete and verified; moves stop before deploy/cleanup.

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const strict = "set -euo pipefail\n"

// packScript writes root/name as a zstd-compressed tar to stdout.
func packScript(root, name string) string {
	return strict + fmt.Sprintf("test -d %s\ntar --numeric-owner --xattrs --acls -C %s -cf - %s | zstd -T0 -q -c\n",
		q(root+"/"+name), q(root), q(name))
}

// unpackScript reads a compressed tar from stdin into root.
func unpackScript(decomp, root string) string {
	return strict + fmt.Sprintf("%s | tar --numeric-owner --xattrs --acls -xpf - -C %s\n", decomp, q(root))
}

// manifestScript prints a stable digest of paths, types, owners and modes
// under root/name (plus sizes for regular files and targets for symlinks),
// then the entry count. Used to verify a copy. Directory sizes are left out:
// they depend on the filesystem and on history (a dir that once held many
// files stays large), and tar does not preserve them.
func manifestScript(root, name string) string {
	return strict + fmt.Sprintf("cd %s\n{ find . -type f -printf '%%P f %%s %%U %%G %%m\\n'; find . ! -type f -printf '%%P %%y - %%U %%G %%m %%l\\n'; } | LC_ALL=C sort | sha256sum | cut -d' ' -f1\nfind . | wc -l\n",
		q(root+"/"+name))
}

// backupTo runs src (which writes a zstd tar to stdout) into out. The file
// only appears at out if src exits 0 and the archive passes `zstd -t`.
func backupTo(src *exec.Cmd, out string) error {
	tmp, err := os.CreateTemp(filepath.Dir(out), "."+filepath.Base(out)+".partial-*")
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		if !ok {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	src.Stdout = tmp
	if src.Stderr == nil {
		src.Stderr = os.Stderr
	}
	if err := src.Run(); err != nil {
		return fmt.Errorf("source: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if out, err := exec.Command("zstd", "-t", "-q", tmp.Name()).CombinedOutput(); err != nil {
		return fmt.Errorf("archive failed integrity check: %v: %s", err, strings.TrimSpace(string(out)))
	}
	if err := os.Rename(tmp.Name(), out); err != nil {
		return err
	}
	ok = true
	return nil
}

// transfer pipes src stdout into sink stdin and fails if either side fails.
func transfer(src, sink *exec.Cmd) error {
	pipe, err := src.StdoutPipe()
	if err != nil {
		return err
	}
	sink.Stdin = pipe
	if src.Stderr == nil {
		src.Stderr = os.Stderr
	}
	if sink.Stderr == nil {
		sink.Stderr = os.Stderr
	}
	if sink.Stdout == nil {
		sink.Stdout = os.Stdout
	}
	if err := src.Start(); err != nil {
		return err
	}
	if err := sink.Start(); err != nil {
		src.Process.Kill()
		src.Wait()
		return err
	}
	// Wait for the sink first: it closes the pipe reader for us via exec.
	sinkErr := sink.Wait()
	srcErr := src.Wait()
	var errs []error
	if srcErr != nil {
		errs = append(errs, fmt.Errorf("read/compress on source: %w", srcErr))
	}
	if sinkErr != nil {
		errs = append(errs, fmt.Errorf("decompress/extract on target: %w", sinkErr))
	}
	return errors.Join(errs...)
}

// copyVerified transfers and then compares manifests from both sides.
// It returns nil only if both sides succeeded and the manifests match.
func copyVerified(src, sink *exec.Cmd, srcManifest, dstManifest func() (string, error)) error {
	if err := transfer(src, sink); err != nil {
		return fmt.Errorf("copy failed: %w", err)
	}
	a, err := srcManifest()
	if err != nil {
		return fmt.Errorf("source manifest: %w", err)
	}
	b, err := dstManifest()
	if err != nil {
		return fmt.Errorf("target manifest: %w", err)
	}
	if strings.TrimSpace(a) == "" || strings.TrimSpace(a) != strings.TrimSpace(b) {
		return fmt.Errorf("copy mismatch: source %q, target %q", strings.TrimSpace(a), strings.TrimSpace(b))
	}
	return nil
}
