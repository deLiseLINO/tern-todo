package main

import (
	"encoding/json"
	"os/exec"
	"strconv"
	"strings"
)

const ternBin = "/Users/delise/.local/bin/tern"

type inspectDoc struct {
	Sessions []struct {
		Tabs []struct {
			Blocks []struct {
				ID     int64 `json:"id"`
				Live   bool  `json:"live"`
				Exited any   `json:"exited"`
			} `json:"blocks"`
		} `json:"tabs"`
	} `json:"sessions"`
}

// livePanes returns the ids of blocks that are live and have not exited.
func livePanes() map[int64]bool {
	live := map[int64]bool{}
	out, err := exec.Command(ternBin, "inspect", "--json").Output()
	if err != nil {
		return live
	}
	var d inspectDoc
	if json.Unmarshal(out, &d) != nil {
		return live
	}
	for _, s := range d.Sessions {
		for _, t := range s.Tabs {
			for _, b := range t.Blocks {
				if b.Live && b.Exited == nil {
					live[b.ID] = true
				}
			}
		}
	}
	return live
}

func focusPane(id int64) error {
	return exec.Command(ternBin, "focus", strconv.FormatInt(id, 10)).Run()
}

func copyText(s string) error {
	c := exec.Command("pbcopy")
	c.Stdin = strings.NewReader(s)
	return c.Run()
}
