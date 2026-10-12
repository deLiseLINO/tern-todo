# tern-todo

A personal to-do list for Tern, a Synara-style Tasks block. It is a Luau plugin (`plugin/`, id `todo-proto`) over one JSON file. Tasks can link to a Tern pane, a working directory and an omp session, and can be handed to omp from the block.

## Open the block

```
tern plugin link <path to>/tern-todo/plugin     # once
tern open --split right my.todo.json             # any *.todo.json (or todos*.json, tern-todo*.json)
```

The file must be `{"todos": [...]}`. The block re-reads it every 5 s (not while a text field is focused) and when the palette command below changes it.

## Keys (no field focused)

| Key | Action |
| --- | --- |
| j / k, Up / Down | move |
| Space, x | toggle done |
| Enter | focus the linked pane; else resume the linked omp chat in a new tab; else start the task in omp |
| Tab, a | add a task (type the title, Enter adds, Esc or Tab leaves the field) |
| e | edit notes (Enter inserts a newline, Esc leaves) |
| F2, n | rename the selected task (whole title selected; Enter, Tab or a click elsewhere commits, Esc restores) |
| p | pick the project (cwd) |
| r | reload the file |
| z | archive / restore the selected task |
| Z | show / hide the Archived section |
| Delete, Backspace | delete (press twice) |

Text fields use Tern's native editing (`features = {edit, undo}`): selection, `cmd+a`, `cmd+c`, double-click a word, undo. The block adds typing, `option+backspace`, `cmd+backspace`, `option+arrows`, redo and `ctrl+a` (select all).

## Mouse and reordering

| Input | What it does |
| --- | --- |
| Double click on a task row | Selects the row, opens its card and does what Enter / the card's primary button does: focuses the linked pane (the window switches to the tab that holds it), else opens `omp --resume <id>` in a new tab and links the pane, else starts the task in omp (model and thinking from the card, the task as the first prompt). A new tab opened this way is shown at once. |
| Single click on a row | Selects the row and opens the card (unchanged). |
| Click on the status glyph | Unchanged: toggles done for plain tasks, opens or starts for agent states. A double click on the glyph or the grip counts as one click: the second press and the row's double click are ignored. |
| Grip (six dots, right edge of a row; shown on hover and on the selected row) | Click picks the task up. The row is outlined, rows of the same group show a drop line (above or below the row under the pointer, depending on which side of the picked task it sits), rows of the other group are dimmed. The next click on a row drops the task there. Click the grip again, press Esc or click anything else to cancel. |
| `Alt+Up` / `Alt+Down` (also `Cmd+Shift+Up` / `Cmd+Shift+Down`) | Moves the selected task one place within its group. Stops at the group's edge. |
| Arrow buttons in the card (next to the priority pill) | The same one-place move; dimmed at the edge of the group. |
| F2, `n`, click on the card title | Rename (unchanged). Double click on a row no longer renames. |

True press-drag-release is not delivered to plugin blocks (Tern sends plugins click, dblclick and menu only), so reordering by mouse is click to pick up, click to put down. It is not drag and drop.

## Order model

The order of the `todos` array in the JSON file is the order of the list inside each group. The list shows three groups: open tasks, done tasks, archived tasks (inside the Archived section). A move only rewrites the array order (every other field, unknown keys, explicit nulls and other top-level keys are kept) through the same re-read, apply by id, write path as every other edit, so a change made to the file by someone else in the meantime survives.

- Dropping on a task of the same group puts the moved task in that task's place: above it when it came from below, below it when it came from above. Every position of the group is reachable (drop on the first row for the top, on the last row for the bottom).
- Dropping on a task of another group puts the moved task at the near edge of its own group: an open task dropped on a done row goes to the end of the open tasks; a done task dropped on an open row goes to the start of the done tasks; an archived task dropped on an open or done row goes to the start of the archived tasks. Tasks never change their done or archived state by moving.
- The moved task stays selected. New tasks are still added at the end of the array.

## Palette command: add an omp session to tasks

`Todo: add this omp session to tasks` (group `Todo`, action `plugin.todo-proto.add-omp-session`). Run it from the pane that runs omp.

- The target file is the most recently opened Todos block's file (published in the plugin's kv as `todo-proto.file`). If no block was opened yet it says `Open the Tasks block once (tern open <file>.todo.json)`.
- The session file comes from `tern inspect --json` (`omp_session_file` of the focused pane). The task title is prefilled with the omp session title; Enter accepts, edit to change, Esc or an empty title cancels. The stored id is the one `omp --resume <id>` takes.
- The task gets `links.tern_pane`, `links.cwd`, `links.omp_session`, priority `none`, no due date.
- A session (or a pane without a session) that is already linked is not added again: the toast says `Already in tasks` and missing or stale links are filled in. Nothing is prompted in that case.
- Errors (no omp in the pane, session not saved yet, the focused pane is not a terminal) toast and leave the file unchanged.

Bind a chord in `settings.json` (`~/Library/Application Support/Tern/settings.json`), there is no default:

```json
"keybinds": { "cmd+shift+t": "plugin.todo-proto.add-omp-session" }
```

## Data format

```json
{
  "todos": [
    {
      "id": "t1",
      "title": "Wire the quota bar",
      "notes": "",
      "priority": "none",
      "due": null,
      "done": false,
      "archived": true,
      "links": { "tern_pane": 12, "cwd": "/Users/me/proj", "omp_session": "01a12f67-4284-74b9-866b-7ca3235b2659" },
      "agent": { "model": "provider/model", "thinking": "high" }
    }
  ]
}
```

- `priority`: `none`, `low`, `medium`, `high`, `urgent`.
- `due`, `links.*`, `agent.*` may be `null`. `archived` is optional (absent = not archived). `agent` is optional (model and thinking level used when the block starts or resumes the task in omp).
- The block rewrites the whole file on every edit with keys sorted alphabetically. Unknown keys and explicit nulls are preserved.
- `links.tern_pane` is a pane id; it can go stale after a restart (the block then treats the task as not running).
