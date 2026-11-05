package backupui

import (
	"fmt"
	"strconv"
)

type badRequest string

func (b badRequest) Error() string { return string(b) }

func parseRev(s string) (int64, error) {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 {
		return 0, badRequest(fmt.Sprintf("bad revision %q", s))
	}
	return n, nil
}
