package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// maxPktData is the largest payload one pkt-line can carry.
const maxPktData = 65516

// readPkt reads one pkt-line. flush is true for a 0000 packet.
func readPkt(r *bufio.Reader) (data []byte, flush bool, err error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, false, err
	}
	n, err := strconv.ParseUint(string(hdr[:]), 16, 16)
	if err != nil {
		return nil, false, fmt.Errorf("bad pkt length %q: %w", hdr, err)
	}
	if n == 0 {
		return nil, true, nil
	}
	if n < 4 {
		return nil, false, fmt.Errorf("unexpected pkt length %d", n)
	}
	data = make([]byte, n-4)
	if _, err := io.ReadFull(r, data); err != nil {
		return nil, false, fmt.Errorf("read pkt: %w", err)
	}
	return data, false, nil
}

// readText reads "key=value" style lines up to a flush.
func readText(r *bufio.Reader) ([]string, error) {
	var lines []string
	for {
		data, flush, err := readPkt(r)
		if err != nil {
			// EOF before anything means git is done with us
			if len(lines) == 0 && errors.Is(err, io.EOF) {
				return nil, io.EOF
			}
			return nil, err
		}
		if flush {
			return lines, nil
		}
		lines = append(lines, strings.TrimSuffix(string(data), "\n"))
	}
}

// readContent reads raw file bytes up to a flush.
func readContent(r *bufio.Reader) ([]byte, error) {
	var out []byte
	for {
		data, flush, err := readPkt(r)
		if err != nil {
			return nil, err
		}
		if flush {
			return out, nil
		}
		out = append(out, data...)
	}
}

func writePkt(w io.Writer, data []byte) error {
	if _, err := fmt.Fprintf(w, "%04x", len(data)+4); err != nil {
		return err
	}
	_, err := w.Write(data)
	return err
}

func writeFlush(w io.Writer) error {
	_, err := io.WriteString(w, "0000")
	return err
}

// writeText writes each line as its own packet, then a flush.
func writeText(w io.Writer, lines ...string) error {
	for _, l := range lines {
		if err := writePkt(w, []byte(l+"\n")); err != nil {
			return err
		}
	}
	return writeFlush(w)
}

// writeContent writes data split into max size packets, then a flush.
func writeContent(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n := min(len(data), maxPktData)
		if err := writePkt(w, data[:n]); err != nil {
			return err
		}
		data = data[n:]
	}
	return writeFlush(w)
}
