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
| Space, x | toggle done; with two or more tasks selected, mark all done, or not done when all are done. Done closes an idle linked pane; not done reopens a linked omp chat. See below for the safety rules. |
| Enter | focus the linked pane; else resume the linked omp chat in a new tab; else start the task in omp |
| Tab, a | add a task (type the title, Enter adds, Esc or Tab leaves the field) |
| e | edit notes (Enter inserts a newline, Tab or a click elsewhere commits, Esc discards the draft) |
| F2, n | rename the selected task (whole title selected; Enter, Tab or a click elsewhere commits, Esc discards the draft) |
| p | pick the project (cwd) |
| r | reload the file |
| z | archive / restore the selected task; with two or more selected, archive all, or restore all when all are archived |
| Z | show / hide the Archived section |
| b | move the selected task to the Backlog, or back to Tasks from there; with two or more selected, the whole selection |
| B | switch between the Tasks and Backlog tabs |
| Delete, Backspace | delete task records only (press twice); with two or more selected, delete the whole selection |
| v | tick / untick the current row |
| Shift+Up / Shift+Down | extend the selection from the anchor row |
| Cmd+A / Ctrl+A | select all visible tasks, including archived tasks only when their section is expanded |
| , | open / close the Settings sheet |
| Esc | cancel a pending delete confirmation or pick-up first; otherwise clear the selection |

Text fields use Tern's native editing (`features = {edit, undo}`): selection, `cmd+a`, `cmd+c`, double-click a word, undo. The block adds typing, `option+backspace`, `cmd+backspace`, `option+arrows`, redo and `ctrl+a` (select all).

`Ctrl+A` selects the whole field even after mouse or Shift-arrow selection and when pressed twice. `Cmd+A` remains Tern's native select-all. Titles and notes save while typing unless the same field changes on disk. A conflict shows `Task changed on disk` once and keeps the local draft visible without overwriting the external edit. Enter, Tab or a click elsewhere explicitly commits a title. Notes keep Enter for a newline; Enter also commits a conflicting draft, while Tab or a click elsewhere commits and leaves notes.

Esc discards a title or notes draft. Without an external edit it restores the value from when editing started; after an external edit it adopts the current disk value without writing. `j/k`, arrows and `g/G` move the cursor without clearing ticks. `e`, `n` / `F2` and `p` do nothing while two or more rows are selected because the task card is hidden.

## Mouse and reordering

| Input | What it does |
| --- | --- |
| Double click on a task row | Selects the row, opens its card and does what Enter / the card's primary button does: focuses the linked pane (the window switches to the tab that holds it), else opens `omp --resume <id>` in a new tab and links the pane, else starts the task in omp (model and thinking from the card, the task as the first prompt). A new tab opened this way is shown at once. |
| Single click on a row | Clears the multi-selection, selects the row and opens its card. Double click also clears the multi-selection and opens only that row. |
| Cmd-click / Ctrl-click on a row | Tick / untick it. The first tick also ticks the current row. |
| Shift-click on a row | Select the range from the anchor row to this row, across groups. The last plain-clicked or Cmd-clicked row sets the anchor. |
| Click on the status glyph | Unchanged: toggles done for plain tasks, opens or starts for agent states. A double click on the glyph or the grip counts as one click: the second press and the row's double click are ignored. |
| Done, Move, Archive and Delete icons in the trailing row box | Shown on hover; also shown on a selected row without a time label. Done toggles that task's status and follows the pane-close/reopen settings. Move sends it to Backlog or back to Tasks. Archive becomes Restore for archived tasks. Delete becomes a red `Delete?`; a second click within 4 seconds removes the record only. Each acts on that row alone and clears multi-selection. The row icons can be hidden in Settings. |
| Grip in the trailing row box | Click picks the task up. The row is outlined, rows of the same group show a drop line above or below the hovered row, and other groups are dimmed. Click a row to drop there. Click the grip again, press Esc or click anything else to cancel. |
| `Alt+Up` / `Alt+Down` (also `Cmd+Shift+Up` / `Cmd+Shift+Down`) | Moves the selected task one place within its group. Stops at the group's edge. |
| Arrow buttons in the card (next to the priority pill) | The same one-place move; dimmed at the edge of the group. |
| F2, `n`, click on the card title | Rename (unchanged). Double click on a row no longer renames. |

True press-drag-release is not delivered to plugin blocks (Tern sends plugins click, dblclick and menu only), so reordering by mouse is click to pick up, click to put down. It is not drag and drop.

Starting a selection cancels a grip pick-up; picking up a row clears the selection. Ticked rows have an accent tint, a left bar and a checked circle. Their status glyphs do not change.

## Bulk panel

With two or more tasks selected the task card becomes `N tasks selected`, with open, done and archived counts. Its buttons are To backlog, Archive, Mark done, Delete and Clear. To backlog becomes Back to tasks for a backlog selection. Archive becomes Restore when all selected tasks are archived; Mark done becomes Mark as not done when all are done. Delete first shows `Delete N?` in red; a second press deletes those records only, never their panes or omp sessions. Confirmation expires after 4 seconds and clears on Esc or a selection change.

Bulk archive, restore and delete each use one read-modify-write by task id. Bulk done writes once after the pane close checks finish; reopening chats then writes their new pane links. External edits, unknown keys and explicit nulls survive. IDs that disappear or become hidden leave the selection on the next re-read. In a narrow window the bulk panel sits above the list.

## Done and the pane

Marking a task done from the keyboard, plain-task glyph, card or bulk panel closes its idle linked pane with `tern close <id>`, then clears `links.tern_pane` to null. The omp session and cwd stay linked. Tern has no confirmation or undo for closing a pane, so the pane stays open with `Pane left open (reason)` when:

- The sampled omp state is working or waiting for input.
- The omp state is unknown, or the foreground job is neither an idle shell nor idle/exited omp. The foreground process is checked with `tern process --json`.
- The pane hosts this task block, another not-done task shares it, or the process check fails.

A dead pane ID is left unchanged. Bulk done shows one summary, such as `Closed 2 panes, left 1 open`. The omp sample can be about 2 seconds old; a new job starting between the check and close is not protected by that earlier check.

Marking a task not done reopens its omp chat in a new tab with `omp --resume <id>` in the task cwd when it has a session but no live pane. A task without a session just becomes open; it does not start an agent. Repeated toggles are ignored while that task's close or reopen is in flight.

Start links the exact saved omp session reported by the new pane, not the newest chat in the project directory. If no saved session is reported within about 20 seconds, the pane remains linked and the chat ID stays unset.

## Row time

Each row shows how long ago the task was last touched at the far right, right aligned with tabular numbers and muted colour. Labels are `now` under 60 seconds or in the future, `Nm`, `Nh`, `Nd` for 1-6 days, `Nw` for 7-29 days, `Nmo` for 30-364 days, and `Ny`. Every step floors. Time and row actions share a fixed trailing box, 168 px when action icons are enabled and 32 px otherwise. Hover fades out time before revealing the done, move, archive, delete and grip controls without shifting or overlapping the title. The selected row keeps its time when not hovered; an armed delete or picked-up row keeps its actions visible instead. The card and time tooltip show the same absolute local date. One minute-aligned timer refreshes the labels, with no per-row timers.

Which moment counts:

| Task | Moment |
| --- | --- |
| done | `completed` (falls back to `updated`, then `created`, when a done task has no `completed`) |
| has a linked omp chat (not done) | the later of `updated` and the chat file's last activity (mtime of `~/.omp/agent/sessions/*/*_<id>.jsonl`, sampled with one `stat` on the 5 s file poll; the file is located once with `find`, retried every 20 s while it is missing) |
| otherwise | `updated`, else `created` |
| no valid stamp | no label |

Tasks created before this version have no stamps and show no label until the block first changes them. Stamps that are not ISO-8601 (`2026-10-12T09:30:00Z`, a fraction and a `+hh:mm` offset are accepted; no zone means UTC) are ignored.

## Settings

The gear in the bottom right corner, the `,` key when no field has focus and the palette command `Todo: settings` open the same centred Settings sheet. The palette command `plugin.todo-proto.settings` works from the focused Todos block; elsewhere it toasts `Focus a Todos block first`. Click a row, or use Up / Down, j / k, Home / End, Space or Enter to flip the selected switch. Esc, `,`, the close button or a click outside closes it. A change applies at once; palette requests reach the block within about 2 seconds.

Settings live in the plugin's kv under `settings` (`<data>/kv.json`), not in the todo file. They are shared by every Todos block and window; other blocks pick a change up within about 2 seconds and the values survive `tern plugin reload` and a restart. A key that was never set uses its default.

Existing `done_group` values from the older `todo-proto.settings` store migrate once into `settings`, without overwriting values already there. The old store is removed after a successful migration; existing setting keys and defaults stay valid.

| Setting | Default | Off means |
| --- | --- | --- |
| Show time on rows | on | no time at the right of rows, no `Updated ...` line in the card, no session file sampling |
| Show row action icons | on | no idle Done, Move, Archive or Delete icons on rows; keyboard deletion still shows `Delete?`; the grip, keyboard shortcuts and bulk panel actions stay available |
| Close pane when a task is done | on | marking done only changes the status; the linked pane stays open and linked |
| Reopen chat when a task is not done | on | marking not done only changes the status; the omp chat is not resumed |
| Double-click opens pane | on | a double click only selects the row and opens its card |
| Show archived section | on | the Archived header and its rows on the Tasks tab are hidden; Z does nothing; archiving still works. Backlog never shows archived tasks. |
| Show badges on rows | on | no priority / pane / omp chips under the title |
| Show agent status on rows | on | no Working / Needs you / Ready for you / Stopped line under the title (the card chip stays) |
| Show key hints | on | no shortcut line at the bottom of the block |
| Done tasks as a separate group | off | done tasks stay in the main list. When on, done tasks leave the main list and sit under a collapsed `Done (N)` header, above the Archived header. Click the header to expand it. Keyboard navigation and selection only see the done rows while the group is expanded. |

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

## Automatic import of omp sessions

While a Todos block is open, the plugin runs `tern inspect --json` every 10 s and adds every pane that runs omp with a saved session the file does not contain yet. The task gets the same links and title as the palette command, plus `created` and `updated` stamps, without a prompt. The open block reloads on its own. Imports go to Tasks, not Backlog.

- Each session is imported at most once (kept in the plugin kv `auto-seen`, last 500 ids). Deleting an imported task does not bring it back while its pane is alive.
- A session whose file is not saved yet, or that has no title and an `omp` pane title, is retried on the next scan.
- The target is the most recently opened Todos block's file, as for the palette command.
- Sessions that are already open when the block first opens are imported too.

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
- `due`, `links.*`, `agent.*` may be `null`. `archived` is optional (absent = not archived). `backlog` is optional (absent = listed on the Tasks tab; `true` = listed on the Backlog tab; archiving a task drops it). `agent` is optional (model and thinking level used when the block starts or resumes the task in omp).
- The block rewrites the whole file on every edit with keys sorted alphabetically. Unknown keys and explicit nulls are preserved.
- `links.tern_pane` is a pane id; it can go stale after a restart (the block then treats the task as not running).
- `created`, `updated`, `completed`: ISO UTC strings the block maintains. `created` is set when a task is added through the block, palette command or automatic import. `updated` is set on every change of that task, including a move between Tasks and Backlog, title, notes, priority, level, model, project, chat and pane links, done and archive. Reordering within a list does not change stamps. `completed` is set when the task turns done and removed when it turns open. Moving lists keeps `created` and `completed`. Tasks the block did not change keep their values and unknown keys; external edits survive the read-modify-write.
