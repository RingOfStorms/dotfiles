package state

// DriveWarnings counts the storage warnings a host would show on the topology
// diagram. The timeline and the diagram must agree on severity, so this is the
// single definition both use:
//
//   - a drive in standby is not a failure (no data was read);
//   - otherwise any unhealthy drive, or one with a non-zero failure counter or
//     wear at 100%, is one warning;
//   - a degraded bcachefs pool is one warning per pool UUID (a pool mounted
//     twice must not count twice).
//
// Hosts without SMART data are simply not counted; nothing here synthesizes a
// failure.
func DriveWarnings(hv HostView) int {
	if hv.Status == nil {
		return 0
	}
	n := 0
	for _, d := range hv.Status.Smart {
		if d.Standby {
			continue
		}
		if !d.Healthy || d.PendingSectors > 0 || d.UncorrectableErrors > 0 ||
			d.MediaErrors > 0 || d.ReallocatedSectors > 0 || d.WearPercentUsed >= 100 {
			n++
		}
	}
	seen := map[string]bool{}
	for _, fs := range hv.Status.Filesystems {
		if fs.Bcachefs == nil || !fs.Bcachefs.Degraded {
			continue
		}
		key := fs.Bcachefs.UUID
		if key == "" {
			key = fs.Mount
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		n++
	}
	return n
}
