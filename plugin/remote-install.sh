#!/bin/sh

status=error
owns_lock=false
lock_dir=
saved_pid=

finish() {
    status=$1
    code=$2
    shift 2
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$*"
    fi
    exit "$code"
}

trap '
    if [ "$owns_lock" = true ]; then
        saved_pid=
        if [ -f "$lock_dir/pid" ] && [ ! -L "$lock_dir/pid" ]; then
            IFS= read -r saved_pid < "$lock_dir/pid"
            if [ "$saved_pid" = "$$" ]; then
                rm -f "$lock_dir/pid"
                rmdir "$lock_dir" 2>/dev/null
            fi
        fi
    fi
    printf "TERN_TODO_REMOTE %s\n" "$status"
' 0

trap 'finish error 1 "Todo installation interrupted; inspect this host before retrying."' 1 2 3 15

if [ -n "${TERN_BIN:-}" ]; then
    tern_bin=$TERN_BIN
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/tern" ]; then
    tern_bin=$HOME/.local/bin/tern
else
    tern_bin=$(command -v tern 2>/dev/null)
fi
if [ -z "$tern_bin" ] || [ ! -x "$tern_bin" ]; then
    finish error 1 'Tern CLI not found. Set TERN_BIN to its executable path on this host.'
fi

if ! plugin_dir=$("$tern_bin" plugin dir 2>&1); then
    printf '%s\n' "$plugin_dir"
    finish error 1 'Cannot locate the Tern plugin directory on this host.'
fi
case "$plugin_dir" in
    /*) ;;
    *) finish error 1 'Tern returned an unsupported plugin directory path.' ;;
esac

read_catalog() {
    catalog=$("$tern_bin" plugin list 2>&1)
    catalog_exit=$?
    package_state=missing
    while IFS= read -r row; do
        case "$row" in
            todo-proto[[:space:]]*)
                case "$row" in
                    *'  failed'|*'  failed:'*) package_state=failed ;;
                    *'  disabled'|*'  disabled:'*) package_state=disabled ;;
                    *'  ready') package_state=ready ;;
                    *) package_state=unknown ;;
                esac
                ;;
        esac
    done <<EOF
$catalog
EOF
    if [ "$catalog_exit" -ne 0 ]; then
        printf '%s\n' "$catalog"
        finish error 1 'Cannot read the Tern plugin catalog on this host. Check the daemon and CLI connection.'
    fi
}

existing_package() {
    case "$package_state" in
        disabled)
            printf '%s\n' "$catalog"
            finish disabled 1 'Todo is disabled on this host. Enable it manually; automatic installation does not change settings.'
            ;;
        failed|unknown)
            printf '%s\n' "$catalog"
            finish failed 1 'Existing Todo is not ready on this host. Inspect its plugin errors; it will not be replaced.'
            ;;
        ready) return 0 ;;
    esac
    if [ -e "$plugin_dir/todo-proto" ] || [ -L "$plugin_dir/todo-proto" ] ||
       [ -e "$plugin_dir/todo-proto.path" ] || [ -L "$plugin_dir/todo-proto.path" ]; then
        finish failed 1 'An existing Todo package or development link is absent from the catalog. Repair it manually; it will not be replaced.'
    fi
    return 1
}

verify_runtime() {
    if ! "$tern_bin" inspect --json >/dev/null; then
        finish error 1 'Cannot inspect the running Tern daemon on this host. Check the CLI connection before retrying.'
    fi
    read_catalog
    case "$package_state" in
        disabled) finish disabled 1 'Todo is disabled on this host; it has not been enabled.' ;;
        failed|unknown) finish failed 1 'Todo failed to load on this host. Inspect the plugin errors above.' ;;
        missing) finish failed 1 'Todo is absent from the runtime catalog. Check the host daemon and plugin directory.' ;;
    esac
}

read_catalog
if existing_package; then
    verify_runtime
    finish present 0
fi
if ! command -v git >/dev/null 2>&1; then
    finish error 1 'Git is required for the first Todo installation. Install Git on this host and reconnect to retry.'
fi
if [ -z "${HOME:-}" ]; then
    finish error 1 'HOME is required for a private Todo installation lock on this host.'
fi

umask 077
lock_root=$HOME/.tern-todo-remote-install
if [ -L "$lock_root" ]; then
    finish error 1 "Refusing a symlink lock namespace: $lock_root"
fi
if [ ! -d "$lock_root" ] && ! mkdir "$lock_root" 2>/dev/null; then
    if [ ! -d "$lock_root" ] || [ -L "$lock_root" ]; then
        finish error 1 "Cannot create private Todo lock namespace: $lock_root"
    fi
fi
permissions=$(LC_ALL=C ls -dn "$lock_root" 2>/dev/null)
IFS=' ' read -r mode _ owner _ <<EOF
$permissions
EOF
current_uid=$(id -u)
case "$mode" in
    drwx------|drwx------@) ;;
    *) finish error 1 "Todo lock namespace must be a private directory with mode 700: $lock_root" ;;
esac
if [ "$owner" != "$current_uid" ]; then
    finish error 1 "Todo lock namespace is not owned by this user: $lock_root"
fi

lock_dir=$lock_root/install.lock
if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] && [ ! -e "$lock_dir/pid" ]; then
        sleep 1
    fi
    lock_pid=
    if [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] &&
       [ -f "$lock_dir/pid" ] && [ ! -L "$lock_dir/pid" ]; then
        IFS= read -r lock_pid < "$lock_dir/pid"
    fi
    case "$lock_pid" in
        ''|*[!0-9]*|0) ;;
        *)
            if kill -0 "$lock_pid" 2>/dev/null; then
                finish busy 1 "Another Todo installer is running on this host, PID $lock_pid."
            fi
            ;;
    esac
    finish error 1 "Todo installation lock has no live owner: $lock_dir. Inspect it, remove only its pid file and empty directory, then reconnect to retry."
fi
owns_lock=true
if ! printf '%s\n' "$$" > "$lock_dir/pid"; then
    rmdir "$lock_dir" 2>/dev/null
    owns_lock=false
    finish error 1 "Cannot record the Todo installation lock owner: $lock_dir"
fi

read_catalog
if existing_package; then
    verify_runtime
    finish present 0
fi
install_output=$("$tern_bin" plugin install github.com/deLiseLINO/tern-todo/plugin 2>&1)
install_exit=$?
if [ -n "$install_output" ]; then
    printf '%s\n' "$install_output"
fi
if [ "$install_exit" -ne 0 ]; then
    finish error 1 'Todo installation failed. Check Git, GitHub access, and plugin directory permissions on this host. Existing files and settings were not replaced.'
fi
reload_output=$("$tern_bin" plugin reload 2>&1)
reload_exit=$?
if [ -n "$reload_output" ]; then
    printf '%s\n' "$reload_output"
fi
if [ "$reload_exit" -ne 0 ]; then
    finish error 1 'Tern runtime reload failed after initial Todo installation. Check this host daemon and the plugin errors above.'
fi
verify_runtime
finish installed 0
