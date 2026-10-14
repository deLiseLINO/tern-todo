# tern-todo

A personal to-do list for Tern, a Synara-style Tasks block. It is a Luau plugin (`plugin/`, id `todo-proto`) over one JSON file. Tasks can link to a Tern pane, a working directory and an omp session, and can be handed to omp from the block.

## Install and open tasks

Install [Tern](https://docs.stencil.so/tern/) and Git on the machine that runs the Tern daemon. Keep a Tern window open when you check plugin readiness.

```sh
tern plugin install github.com/deLiseLINO/tern-todo/plugin
tern plugin list
```

The list must show `todo-proto` as ready. Check the window for plugin error toasts too, because `tern plugin list` does not report window-entry failures. In the command palette, run **Todo: open tasks**. You can also invoke the command from a terminal attached to that window:

```sh
tern ctl plugins run plugin.todo-proto.open
```

The command opens `todo-proto.list` without a file argument. The host selects its last task file from `tern.kv` key `todo-proto.file`, or `$HOME/todos.todo.json` if no file was saved. It creates `{"todos": []}` only when that file is absent. Existing files are read, not reset. An unreadable file, invalid JSON, a creation failure, or missing host `HOME` appears as an error in the block. A missing or failed host plugin produces a toast instead.

The palette offers **Todo: open tasks** as the only task-list opening command. The automatic **New Todos block** entry is hidden; file opens and **Open with Todos** remain available.

To open a different file, pass its path explicitly:

```sh
tern open --split right /path/to/my.todo.json
```

An explicit path stays unchanged and takes precedence over the saved path and `HOME`. Create the file with `{"todos": []}` first. Explicit file opens do not create missing files. Routes accept `*.todo.json`; the manifest also accepts `todos*.json` and `tern-todo*.json`. An absolute path becomes the last task file for later no-argument opens.

### Update an installed copy

```sh
tern plugin install github.com/deLiseLINO/tern-todo/plugin --force
tern plugin list
```

`--force` replaces an installed copy, not a development link. Task files and plugin settings are separate from the installed package. Each open block saves its selected path, so reloading does not switch it to a different block's last file.

### Link a development checkout

Use a link only when you want Tern to load your working files in place:

```sh
git clone https://github.com/deLiseLINO/tern-todo.git
tern plugin link ./tern-todo/plugin
tern plugin list
```

To switch a linked package to a repository installation, run `tern plugin unlink todo-proto`, then install it with the command above. `tern plugin reload` reloads linked or installed code. Linking and reloading do not deliver `window_start` to an already open window.

### Remote hosts

Automatic installation is off by default. On the local window, run **Todo: automatic installation on remote hosts** to toggle the saved setting. Todo checks connected remote hosts every two seconds and installs `github.com/deLiseLINO/tern-todo/plugin` only where the package is missing. It never updates an installed copy, replaces a development link, or enables a disabled plugin.

The installer runs through Tern's attached host connection, not SSH. It creates a dedicated shell pane and restores your previous focus. It closes that pane after success only if you have not focused it and its own command has finished. Failures leave the pane open and report the host in a notification. Automatic attempts stop after a failure until the host reconnects. You can also run **Todo: open tasks** to retry. Turning the setting off stops new installations, not an installer already running.

Switch the window to the remote host before running **Todo: open tasks**. If Todo is missing and automatic installation is enabled, the command waits for installation and the host catalog. If you switch hosts or sessions meanwhile, it does not open a block in the wrong place. Manual installation remains available with `tern plugin install github.com/deLiseLINO/tern-todo/plugin`.

Each host selects its own task file from its `todo-proto.file` setting or `HOME`. Installation does not copy your local task file.

Concurrent installers use a private lock at `$HOME/.tern-todo-remote-install/install.lock`. Normal exit and caught signals remove only the installer's own lock. A killed process can leave a stale lock. Inspect its `pid` file and confirm that PID is no longer running before removing the file with `rm "$HOME/.tern-todo-remote-install/install.lock/pid"` and the empty directory with `rmdir "$HOME/.tern-todo-remote-install/install.lock"`. Reconnect to retry. Never remove an active installer's lock.

To toggle automatic installation from the attached window's terminal:

```sh
tern ctl plugins run plugin.todo-proto.remote-auto-install
```

Task opening, manual and automatic session import, session discovery, and task writes use the selected host's files. The window sends host-scoped agent states and settings actions through Tern's native connection. Pane-close safety reads native state directly from the owning host and does not depend on the window sampler. Closing a pane completes its linked task on that host; losing the connection does not. Settings are stored separately on each host. Todo must be version 0.4.0 or later in the window and on every attached host for this integration. Automatic installation does not upgrade existing copies.

### Requirements and platform limits

- Tern must support Luau plugins and `WindowCx:new_block` on the current host. Automatic installation also requires native host terminals and pane inspection in the local window. Remote hosts must already be attached and trusted, with a running Tern daemon and its plugin CLI. The installer does not bootstrap Tern or bypass host verification.
- Automatic remote installation requires Unix `/bin/sh`, `HOME`, standard shell utilities, and writable user-owned home and plugin directories. Git and GitHub access are required only when Todo is missing. No SSH, jq, or Python is needed. Initial installation must pass a runtime reload and report Todo ready. Unrelated plugin errors can also fail the reload.
- The remote installer resolves its host's `TERN_BIN`, then `$HOME/.local/bin/tern`, then `tern` on the shell's `PATH`. Set `TERN_BIN` if neither standard path finds the CLI.
- The daemon must receive `HOME` for a default task file. Set `TERN_BIN` to an absolute executable path if Tern is installed elsewhere. Each plugin half resolves it once, in this order: `TERN_BIN`, `$HOME/.local/bin/tern`, `/opt/homebrew/bin/tern`, `/usr/local/bin/tern`, `/usr/bin/tern`, then `tern` through its process environment's `PATH`. An explicit override is used as given. Restart the daemon or reload the plugin after changing its environment.
- omp is optional for plain tasks, but required to start or resume agents and load models or chats. `OMP_BIN` overrides its location. Otherwise the host looks in `$HOME/.local/bin`, `$HOME/.bun/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`, then tries `omp`.
- The plugin calls Tern for pane inspection, focus, creation, process inspection, and closing. It calls `/usr/bin/head` for omp session headers, `/usr/bin/find` and `/usr/bin/stat` for session discovery and times, and `/bin/ls` for project directory completion.
- `fswatch` is optional. The plugin expects `/opt/homebrew/bin/fswatch`, installed on Apple Silicon macOS with `brew install fswatch`. It reloads a changed file within about 0.2 seconds when the watcher runs, except while a text field has focus. A 5-second file poll is the fallback.
- Task editing, omp-session import, chat and model selection, launch and resume, and pane lifecycle run on macOS and Linux hosts with Tern plugins. Session metadata uses BSD `stat -f` on macOS and GNU `stat -c` on Linux. Windows is not supported. A Linux host uses the 5-second file poll unless `/opt/homebrew/bin/fswatch` is available.

Todo resolves pane IDs reported by Tern's window APIs against the owning daemon's pane list. This preserves session import and agent status when long-running daemons allocate IDs above 2^44. Tasks keep the full daemon ID in `links.tern_pane`; the shorter window ID is used only for transport. If two live panes share the same shorter ID, import reports an error rather than linking the wrong pane.

### Files and state

The plugin creates the host-selected default or last task file if absent, then rewrites the selected JSON file when you edit tasks. It preserves unknown keys and explicit nulls during those edits. Host-side omp import can also add tasks to the last selected file.

Settings, the last absolute task file, the last selected project, import history, and reload counters go into the plugin's `tern.kv` store, `<data>/kv.json`. The plugin reads omp session headers and file metadata under `$HOME/.omp/agent/sessions`; it does not rewrite those sessions directly. Starting or resuming omp can make omp write its own session files. No runtime files are written into `plugin/`.

## Contribute through GitHub

The source repository is [deLiseLINO/tern-todo](https://github.com/deLiseLINO/tern-todo), with `main` as its default branch. Open code pull requests there, not in the GitLab parent repository.

When this project is checked out inside `slop`, it is a Git submodule. Create task worktrees from the tern-todo repository and follow `AGENTS.md`. The parent repository records the submodule commit and does not hold a second copy of the source.

## Keys (no field focused)

| Key | Action |
| --- | --- |
| j / k, Up / Down | move |
| Space, x | toggle done; with two or more tasks selected, mark all done, or not done when all are done. Done closes an idle linked pane; not done reopens a linked omp chat. See below for the safety rules. |
| Enter | focus the linked pane; else resume the linked omp chat in a new tab; else start the task in omp |
| Tab, a | new task: opens its card with the last picked project preselected and puts the caret in the add field; the draft stays in memory until Enter accepts the title; Esc, closing the block, reloading, or leaving the field discards it |
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

Bulk archive, backlog and done each write once after the pane close checks finish. Restore and delete each use one read-modify-write by task id. Reopening chats then writes their new pane links. External edits, unknown keys and explicit nulls survive. IDs that disappear or become hidden leave the selection on the next re-read. In a narrow window the bulk panel sits above the list.

## Done, archive, backlog and the pane

Closing a linked tab or pane marks its tasks done, records the completion time, and clears `links.tern_pane`. The omp session and cwd stay linked. This works while a Todos block watches the file, even when that block is in a background tab. Completion waits until you leave an active text field. A pane ID already missing when the block opens does not complete a task. Exiting omp without closing its pane does not complete a task. The `Close pane on done, archive or backlog` setting controls the opposite direction only.

Marking a task done, archiving it, or moving it to Backlog closes its idle linked pane with `tern close <id>`, then clears `links.tern_pane` to null. This applies to keyboard, row, card and bulk actions. Archive preserves the done status. Backlog clears it. Restoring a task or moving it back to Tasks does not reopen its chat. The omp session and cwd stay linked. Tern has no confirmation or undo for closing a pane, so the pane stays open with `Pane left open (reason)` when:

- The owning host reports that omp is working or waiting for input.
- The host cannot confirm an idle saved omp session, or the foreground job is neither an idle shell nor omp. The host checks `tern inspect --json` and `tern process --json`.
- The pane hosts this task block, another not-done task shares it, or the process check fails.

Pane closures initiated by Done, Archive or Backlog do not trigger automatic completion in other Todos blocks. Multiple blocks watching the same file preserve the requested task status.

A dead pane ID is left unchanged. Bulk pane closure shows one summary, such as `Closed 2 panes, left 1 open`. A new job that starts between the host inspection and the close is not protected by that earlier check.

Marking a task not done reopens its omp chat in a new tab with `omp --resume <id>` in the task cwd when it has a session but no live pane. A task without a session just becomes open; it does not start an agent. Repeated toggles are ignored while that task's close or reopen is in flight.

Start links the exact saved omp session reported by the new pane, not the newest chat in the project directory. If no saved session is reported within about 20 seconds, the pane remains linked and the chat ID stays unset.

The chat selector shows the title of the linked omp chat, reading the chat's file even when it is older than the recent-chats list, and ends a long title with an ellipsis before the arrow. While the title loads it shows `Loading chat…`; a chat whose file cannot be found shows `Unknown chat`, retried every 20 s.

The task card has a mode button to the right of the project selector, in the same pill style. The two never separate: a long project name ends with an ellipsis, and when the card is narrow the pair wraps together. If the task's directory is a linked Git worktree, the project selector shows the repository name followed by `(wt)`, for example `tern-todo (wt)`, not the generated worktree directory name. Git resolves the name once per directory, and the directory name shows until it answers. The button shows **Worktree** by default; each click switches between **Local** and **Worktree**. The choice is shared through Settings. A new chat creates a Git branch and worktree under `~/.omp/wt/` from the project's default origin branch, or `main` or `master` when no default origin branch is recorded. The task keeps the worktree directory in `links.cwd`, so reopening its chat uses the same directory. With **Local** selected, Start uses the task's project directory. Existing chats never create a worktree when resumed. A non-Git directory or a failed worktree creation shows an error and does not start omp. Worktrees remain after a pane closes or a task is deleted.

The agent status stays `Needs you` while an omp `ask` question is visible in the editor, even when the approval layer is empty.

## Row time

Each row shows how long ago the task was last touched at the far right, right aligned with tabular numbers and muted colour. Labels are `now` under 60 seconds or in the future, `Nm`, `Nh`, `Nd` for 1-6 days, `Nw` for 7-29 days, `Nmo` for 30-364 days, and `Ny`. Every step floors. Time and row actions share a fixed trailing box, 168 px when action icons are enabled and 32 px otherwise. Hover fades out time before revealing the done, move, archive, delete and grip controls without shifting or overlapping the title. The selected row keeps its time when not hovered; an armed delete or picked-up row keeps its actions visible instead. The card and time tooltip show the same absolute local date. One minute-aligned timer refreshes the labels, with no per-row timers.

Rows hide the relative time only while the agent is Working. Starting, Needs you, Ready for you, Stopped and done tasks keep their time labels. The time returns when the agent stops working, even if the agent status line is hidden in Settings. The timestamp in the task card stays visible during work.

Which moment counts:

| Task | Moment |
| --- | --- |
| done | `completed` (falls back to `updated`, then `created`, when a done task has no `completed`) |
| has a linked omp chat (not done) | the later of `updated` and the chat file's last activity (mtime of `~/.omp/agent/sessions/*/*_<id>.jsonl`, sampled with one `stat` after each `fswatch` event on a known chat file and on the 5 s file poll; the file is located once with `find`, retried every 20 s while it is missing) |
| otherwise | `updated`, else `created` |
| no valid stamp | no label |

Tasks created before this version have no stamps and show no label until the block first changes them. Stamps that are not ISO-8601 (`2026-10-12T09:30:00Z`, a fraction and a `+hh:mm` offset are accepted; no zone means UTC) are ignored.

## Settings

The gear in the bottom right corner, the `,` key when no field has focus and the palette command `Todo: settings` open the same centred Settings sheet. The palette command `plugin.todo-proto.settings` works from the focused Todos block; elsewhere it toasts `Focus a Todos block first`. Click a row, or use Up / Down, j / k, Home / End, Space or Enter to flip the selected switch. Esc, `,`, the close button or a click outside closes it. A change applies at once; palette requests reach the block within about 0.2 seconds.

Settings live in the plugin's kv under `settings` (`<data>/kv.json`), not in the todo file. They are shared by every Todos block and window; other blocks pick a change up within about 0.2 seconds and the values survive `tern plugin reload` and a restart. A key that was never set uses its default.

Existing `done_group` values from the older `todo-proto.settings` store migrate once into `settings`, without overwriting values already there. The old store is removed after a successful migration; existing setting keys and defaults stay valid.

| Setting | Default | Off means |
| --- | --- | --- |
| Show time on rows | on | no time at the right of rows, no `Updated ...` line in the card, no session file sampling |
| Show row action icons | on | no idle Done, Move, Archive or Delete icons on rows; keyboard deletion still shows `Delete?`; the grip, keyboard shortcuts and bulk panel actions stay available |
| Close pane on done, archive or backlog | on | done, archive and move to Backlog only change the task; the linked pane stays open and linked |
| Reopen chat when a task is not done | on | marking not done only changes the status; the omp chat is not resumed |
| Open pane when a task starts | on | starting or resuming a task still opens and links its tab, but leaves it in the background instead of switching to it |
| Create new chats in a worktree | on | new chats start in the task's project directory without creating a Git worktree; existing chats always keep their directory |
| Double-click opens pane | on | a double click only selects the row and opens its card |
| Show archived section | on | the Archived header and its rows on the Tasks tab are hidden; Z does nothing; archiving still works. Backlog never shows archived tasks. |
| Show badges on rows | on | no priority / pane / omp chips under the title |
| Show agent status on rows | on | no Working / Needs you / Ready for you / Stopped line under the title (the card chip stays) |
| Show key hints | on | no shortcut line at the bottom of the block |
| Done tasks as a separate group | off | done tasks stay in the main list. When on, done tasks leave the main list and sit under a collapsed `Done (N)` header, above the Archived header. Click the header to expand it. Keyboard navigation and selection only see the done rows while the group is expanded. |
| Task titles from omp | off | task titles stay as you typed them. When on, the 10 s scan (see "Automatic import") copies the title omp gave a session onto the task linked to it, even if you named the task yourself. A title you typed then works as the first prompt: it is sent to omp when you start the task, and omp's name replaces it afterwards. A renamed task is overwritten again at the next scan while omp's title differs. A session without an omp title leaves the task title alone. The scan runs only while a Todos block is open. |

## Order model

The order of the `todos` array in the JSON file is the order of the list inside each group. The list shows three groups: open tasks, done tasks, archived tasks (inside the Archived section). A move only rewrites the array order (every other field, unknown keys, explicit nulls and other top-level keys are kept) through the same re-read, apply by id, write path as every other edit, so a change made to the file by someone else in the meantime survives.

- Dropping on a task of the same group puts the moved task in that task's place: above it when it came from below, below it when it came from above. Every position of the group is reachable (drop on the first row for the top, on the last row for the bottom).
- Dropping on a task of another group puts the moved task at the near edge of its own group: an open task dropped on a done row goes to the end of the open tasks; a done task dropped on an open row goes to the start of the done tasks; an archived task dropped on an open or done row goes to the start of the archived tasks. Tasks never change their done or archived state by moving.
- The moved task stays selected. New tasks are inserted at the beginning of the array, so they appear first in Tasks or Backlog. This also applies to the palette command and automatic omp import. Existing tasks keep their relative order.

## Palette command: add an omp session to tasks

`Todo: add this omp session to tasks` (group `Todo`, action `plugin.todo-proto.add-omp-session`). Run it from the pane that runs omp.

- The target file is the most recently opened Tasks block's file on the selected host, saved as `todo-proto.file`. Open Tasks once on that host before adding a session. Todo must be version 0.3.1 or later on both the local window and the remote host; automatic installation does not upgrade an existing package.
- A temporary background plugin block reads the focused pane's `omp_session_file` and its first two session-file lines on that same host. The window reads its retained native surface even while the helper tab is hidden. It never types into the omp pane or copies local tasks to the host. The title prompt stays in your window; Enter accepts, Esc or an empty title cancels. The temporary block closes after completion or cancellation. The stored id is the one `omp --resume <id>` takes.
- The task gets `links.tern_pane`, `links.cwd`, `links.omp_session`, priority `none`, no due date.
- A session (or a pane without a session) that is already linked is not added again: the toast says `Already in tasks` and missing or stale links are filled in. Nothing is prompted in that case.
- Errors (no omp in the pane, session not saved yet, the focused pane is not a terminal) toast and leave the file unchanged.

Bind a chord in `settings.json` (`~/Library/Application Support/Tern/settings.json`), there is no default:

```json
"keybinds": { "cmd+shift+t": "plugin.todo-proto.add-omp-session" }
```

## Automatic import of omp sessions

While a Todos block is open, its host runs `tern inspect --json` every 10 s and adds every pane that runs omp with a saved session the file does not contain yet. The task gets the same links and title as the palette command, plus `created` and `updated` stamps, without a prompt. The open block reloads on its own. Imports go to Tasks, not Backlog.

- Each session is imported at most once, with the last 500 ids in the plugin kv `auto-seen`. Confirmed task deletion records its linked session there too, including tasks deleted before their first automatic scan.
- A session whose file is not saved yet is retried on the next scan. A saved session without a title appears as `omp session`. The existing Task titles from omp setting can replace that title later.
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
- Backlog and done are mutually exclusive. Marking a task done removes `backlog`. Moving a done task to Backlog clears `done` and `completed`, without reopening its chat. An existing task with both flags appears only in Tasks as done; the next file edit removes its `backlog` flag.
- The block rewrites the whole file on every edit with keys sorted alphabetically. Unknown keys and explicit nulls are preserved.
- `links.tern_pane` is a pane id; it can go stale after a restart (the block then treats the task as not running).
- `created`, `updated`, `completed`: ISO UTC strings the block maintains. `created` is set when a task is added through the block, palette command or automatic import. `updated` is set on every change of that task, including a move between Tasks and Backlog, title, notes, priority, level, model, project, chat and pane links, done and archive. Reordering within a list does not change stamps. `completed` is set when the task turns done and removed when it turns open. Moving lists keeps `created`; moving a done task to Backlog removes `completed`. Tasks the block did not change keep their values and unknown keys; external edits survive the read-modify-write.

The Tasks workspace scrolls when its rows and detail card exceed the pane height. Keyboard hints stay on one clipped line in narrow splits, so the dock does not hide the task list.
