// Package proto is the probe's tiny echo protocol shared by both ends.
package proto

import (
	"encoding/binary"
	"io"
	"time"

	"github.com/tmc/go-iroh/iroh"
)

// ALPN identifies the probe protocol.
const ALPN = "tam-irohprobe/1"

// Transport keeps relay-only paths alive through mobile NATs.
func Transport() *iroh.QUICTransportConfig {
	return &iroh.QUICTransportConfig{KeepAlivePeriod: 5 * time.Second, MaxIdleTimeout: 30 * time.Second}
}

func WriteFrame(w io.Writer, p []byte) error {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(p)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(p)
	return err
}

func ReadFrame(r io.Reader) ([]byte, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n > 1<<20 {
		return nil, io.ErrShortBuffer
	}
	p := make([]byte, n)
	_, err := io.ReadFull(r, p)
	return p, err
}
