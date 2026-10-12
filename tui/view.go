package main

import (
	"fmt"

	"github.com/stencil-hq/tern-sdk/go/tern"
	"github.com/stencil-hq/tern-sdk/go/tern/ui"
)

type state struct {
	todos  []Todo
	sel    int
	live   map[int64]bool
	status string
}

var priorityTone = map[string]string{
	"urgent": "error", "high": "warning", "medium": "info", "low": "muted", "none": "dim",
}

func toneOf(p string) ui.Tone {
	switch p {
	case "urgent":
		return ui.ToneError
	case "high":
		return ui.ToneWarning
	case "medium":
		return ui.ToneInfo
	}
	return ui.ToneMuted
}

func paneTone(t Todo, live map[int64]bool) ui.Tone {
	if t.Links.TernPane != nil && live[*t.Links.TernPane] {
		return ui.ToneSuccess
	}
	return ui.ToneError
}

func rowSpans(t Todo, live map[int64]bool) ui.Rich {
	title, pri := "strong", priorityTone[t.Priority]
	box := "[ ] "
	if t.Done {
		title, pri, box = "muted del", "muted", "[x] "
	}
	return ui.Spans(
		ui.Span{T: box, S: "muted"},
		ui.Span{T: fmt.Sprintf("%-6s ", t.Priority), S: pri},
		ui.Span{T: t.Title, S: title},
	)
}

func rowValue(t Todo, live map[int64]bool) ui.Rich {
	var sp []ui.Span
	if t.Links.TernPane != nil {
		s := "success"
		if !live[*t.Links.TernPane] {
			s = "error"
		}
		sp = append(sp, ui.Span{T: "pane ", S: s})
	}
	if t.Links.OmpSession != nil {
		sp = append(sp, ui.Span{T: "omp ", S: "accent"})
	}
	if t.Due != nil {
		sp = append(sp, ui.Span{T: *t.Due, S: "num muted"})
	}
	return ui.Spans(sp...)
}

func itemKey(t Todo) string { return "t:" + t.ID }

func detail(t Todo, live map[int64]bool) tern.Element {
	due, pane, cwd, omp := "-", "-", "-", "-"
	if t.Due != nil {
		due = *t.Due
	}
	if t.Links.TernPane != nil {
		state := "dead"
		if live[*t.Links.TernPane] {
			state = "alive"
		}
		pane = fmt.Sprintf("%d (%s)", *t.Links.TernPane, state)
	}
	if t.Links.Cwd != nil {
		cwd = *t.Links.Cwd
	}
	if t.Links.OmpSession != nil {
		omp = *t.Links.OmpSession
	}
	badges := []tern.Element{ui.Badge{Text: t.Priority, Common: ui.Common{Tone: toneOf(t.Priority)}}}
	if t.Done {
		badges = append(badges, ui.Badge{Text: "done", Common: ui.Common{Tone: ui.ToneMuted}})
	}
	if t.Links.TernPane != nil {
		badges = append(badges, ui.Badge{Text: "pane", Common: ui.Common{Tone: paneTone(t, live)}})
	}
	if t.Links.OmpSession != nil {
		badges = append(badges, ui.Badge{Text: "omp", Common: ui.Common{Tone: ui.ToneAccent}})
	}
	return ui.Card{
		Common: ui.Common{Key: "detail"},
		Head:   ui.T(t.Title),
		Children: ui.Nodes(
			ui.Row{Common: ui.Common{Key: "badges"}, Gap: ui.GapSM, Children: badges},
			ui.Md{Common: ui.Common{Key: "notes"}, Text: t.Notes},
			ui.KV{Common: ui.Common{Key: "kv"}, Items: []ui.Pair{
				{K: ui.T("priority"), V: ui.T(t.Priority)},
				{K: ui.T("due"), V: ui.T(due)},
				{K: ui.T("tern pane"), V: ui.T(pane)},
				{K: ui.T("cwd"), V: ui.T(cwd)},
				{K: ui.T("omp session"), V: ui.T(omp)},
			}},
		),
	}
}

func dockHints(status string) tern.Element {
	segs := ui.Nodes(
		ui.Seg{Common: ui.Common{Key: "nav"}, Text: "j/k move"},
		ui.Seg{Common: ui.Common{Key: "tog"}, Text: "space toggle done"},
		ui.Seg{Common: ui.Common{Key: "go"}, Text: "enter focus pane / copy omp resume"},
		ui.Seg{Common: ui.Common{Key: "q"}, Text: "q quit"},
	)
	if status != "" {
		segs = append(segs, ui.Seg{Common: ui.Common{Key: "msg"}, Text: status, Side: ui.SideRight})
	}
	return ui.Status{Common: ui.Common{Key: "bar"}, Children: segs}
}

// render is a pure function of the state; it also feeds the plain fallback.
func render(s state) tern.View {
	items := make([]tern.Element, len(s.todos))
	selected := ""
	for i, t := range s.todos {
		items[i] = ui.Item{
			Common: ui.Common{Key: itemKey(t)},
			Label:  rowSpans(t, s.live),
			Value:  rowValue(t, s.live),
		}
		if i == s.sel {
			selected = "main.list." + itemKey(t)
		}
	}
	main := tern.Nodes{
		ui.List{
			CommonWithoutMax: ui.CommonWithoutMax{Key: "list"},
			Selected:         selected,
			Empty:            ui.T("No todos"),
			Children:         items,
		},
	}
	if s.sel >= 0 && s.sel < len(s.todos) {
		main = append(main, detail(s.todos[s.sel], s.live))
	}
	return tern.View{Main: main, Dock: tern.Nodes{dockHints(s.status)}}
}
