package main

import (
	"encoding/json"
	"os"
	"sort"
)

type Links struct {
	TernPane   *int64  `json:"tern_pane"`
	Cwd        *string `json:"cwd"`
	OmpSession *string `json:"omp_session"`
}

type Todo struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	Notes    string  `json:"notes"`
	Priority string  `json:"priority"`
	Due      *string `json:"due"`
	Done     bool    `json:"done"`
	Links    Links   `json:"links"`
}

type fileData struct {
	Todos []Todo `json:"todos"`
}

func load(path string) ([]Todo, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var d fileData
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, err
	}
	sortTodos(d.Todos)
	return d.Todos, nil
}

func save(path string, todos []Todo) error {
	b, err := json.MarshalIndent(fileData{Todos: todos}, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// sortTodos puts open items before done ones, keeping file order otherwise.
func sortTodos(todos []Todo) {
	sort.SliceStable(todos, func(i, j int) bool { return !todos[i].Done && todos[j].Done })
}
