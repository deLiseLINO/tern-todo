// Command tern-todo-tui is a to-do list drawn natively in Tern through the
// Tern Surface Protocol; outside Tern it prints the same view as plain text.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/stencil-hq/tern-sdk/go/tern"
)

func main() {
	file := flag.String("file", "", "path to the todos JSON file (required)")
	flag.Parse()
	if *file == "" {
		fmt.Fprintln(os.Stderr, "usage: tern-todo-tui --file <path>")
		os.Exit(2)
	}
	todos, err := load(*file)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	st := state{todos: todos, live: livePanes()}
	if err := run(&st, *file); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(st *state, file string) error {
	ctx := context.Background()
	s, err := tern.Connect(ctx, tern.Options{App: "tern-todo"})
	if errors.Is(err, tern.ErrUnsupported) {
		fmt.Print(tern.Plain(render(*st), 100))
		return nil
	}
	if err != nil {
		return err
	}
	defer s.Close()
	sf, err := s.Open(tern.SurfaceOptions{Mode: tern.Screen})
	if err != nil {
		return err
	}
	defer sf.Close()
	draw := func() error { return sf.Render(render(*st)) }
	if err := draw(); err != nil {
		return err
	}
	return s.Run(ctx, func(in tern.Input) error {
		k, ok := in.(tern.Key)
		if !ok {
			return nil
		}
		if k.Is("q") || k.Is("ctrl+c") {
			return tern.ErrStop
		}
		handleKey(st, k, file)
		return draw()
	})
}

func handleKey(st *state, k tern.Key, file string) {
	n := len(st.todos)
	if n == 0 {
		return
	}
	switch {
	case k.Is("j") || k.Is("down"):
		st.sel = min(st.sel+1, n-1)
	case k.Is("k") || k.Is("up"):
		st.sel = max(st.sel-1, 0)
	case k.Is("space") || k.Is(" ") || k.Is("x"):
		id := st.todos[st.sel].ID
		st.todos[st.sel].Done = !st.todos[st.sel].Done
		sortTodos(st.todos)
		for i, t := range st.todos {
			if t.ID == id {
				st.sel = i
			}
		}
		if err := save(file, st.todos); err != nil {
			st.status = "save failed: " + err.Error()
		} else {
			st.status = "saved"
		}
	case k.Is("enter"):
		st.live = livePanes()
		st.status = activate(st.todos[st.sel], st.live)
	}
}

func activate(t Todo, live map[int64]bool) string {
	if t.Links.TernPane != nil && live[*t.Links.TernPane] {
		if err := focusPane(*t.Links.TernPane); err != nil {
			return "focus failed: " + err.Error()
		}
		return fmt.Sprintf("focused pane %d", *t.Links.TernPane)
	}
	if t.Links.OmpSession != nil {
		cmd := "omp --resume " + *t.Links.OmpSession
		if err := copyText(cmd); err != nil {
			return cmd
		}
		return "copied: " + cmd
	}
	return "no live pane or omp session"
}
