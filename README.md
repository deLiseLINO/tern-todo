# tern-todo

![Task detail card in Tern, dark theme](https://raw.githubusercontent.com/deLiseLINO/tern-todo/4ef78a54b5d954634372f9eb9bd7c1c940939c43/shots/auto-title-dark-on.png)

## Install

Install [Tern](https://docs.stencil.so/tern/) and Git on the machine that runs the Tern daemon. The plugin supports macOS and Linux.

With a Tern window open, run:

```sh
tern plugin install github.com/deLiseLINO/tern-todo/plugin
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
tern plugin install github.com/deLiseLINO/tern-todo/plugin --force
tern plugin list
```

Task files and settings stay intact. If you previously linked a development checkout, run `tern plugin unlink todo-proto` before installing.

## Install on a remote host

Run the installation commands on each remote host that runs Tern. Switch the Tern window to that host, then run **Todo: open tasks**.

For automatic installation on connected hosts, enable **Todo: automatic installation on remote hosts** in the local window's command palette. This installs missing copies only. Update existing copies manually.
