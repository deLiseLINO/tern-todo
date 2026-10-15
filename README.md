# tern-todo

![Task list and detail card in Tern, dark theme](https://raw.githubusercontent.com/deLiseLINO/tern-todo/341b91aa29ca420e63a285d29772d490217e2672/shots/tasks-dark.png)

## Install

Install [Tern](https://docs.stencil.so/tern/) and Git on the machine that runs the Tern daemon. The plugin runs inside Tern on macOS and Linux.

With a Tern window open, run:

```sh
tern plugin install github.com/deLiseLINO/tern-todo
tern plugin list
```

Check that `todo-proto` is ready and that the window shows no plugin errors.

In the command palette, run **Todo: open tasks**. Or run this command from a terminal in that window:

```sh
tern ctl plugins run plugin.todo-proto.open
```

On the first launch, the plugin creates `~/todos.todo.json`. Later launches use the last selected task file on that host.

## Update

```sh
tern plugin install github.com/deLiseLINO/tern-todo --force
tern plugin list
```

Task files and settings stay intact. If you previously linked a development checkout, run `tern plugin unlink todo-proto` before installing.

## Install on a remote host

Run the installation commands on each remote host that runs Tern. Switch the Tern window to that host, then run **Todo: open tasks**.

For automatic installation on connected hosts, enable **Todo: automatic installation on remote hosts** in the local window's command palette. This installs missing copies only. Update existing copies manually.
