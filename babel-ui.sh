# babel-ui shell commands — source this from ~/.zshrc or ~/.bashrc:
#
#   source /path/to/babel-ui/babel-ui.sh
#
#   babel-ui              start the panel (if not running) and open it in a new browser window
#   babel-ui-stop         stop it
#   babel-ui-stop --all   also close the shared ssh connection to the cluster
#
# Settings come from the environment or from .env next to this file (see .env.example).

if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: path of the file being sourced (bash would choke on this syntax, hence eval)
  eval 'BABEL_UI_DIR="${${(%):-%x}:A:h}"'
else
  BABEL_UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Print one setting ($1): the shell's value if set, else .env's, else the default ($2).
_babel_ui_cfg() {
  local v
  eval "v=\${$1-}"
  if [ -z "$v" ] && [ -f "$BABEL_UI_DIR/.env" ]; then
    v="$(set -a; . "$BABEL_UI_DIR/.env" >/dev/null 2>&1; eval "printf '%s' \"\${$1-}\"")"
  fi
  printf '%s' "${v:-$2}"
}

_babel_ui_python() {
  local py
  py="$(_babel_ui_cfg BABEL_UI_PYTHON "")"
  if [ -n "$py" ]; then printf '%s' "$py"
  elif [ -x "$BABEL_UI_DIR/.venv/bin/python" ]; then printf '%s' "$BABEL_UI_DIR/.venv/bin/python"
  else printf '%s' python3
  fi
}

_babel_ui_log() {
  if [ -d "$HOME/Library/Logs" ]; then printf '%s' "$HOME/Library/Logs/babel-ui.log"
  else mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}"; printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/babel-ui.log"
  fi
}

babel-ui() {
  local port url log i browser
  port="$(_babel_ui_cfg BABEL_UI_PORT 8765)"
  url="http://127.0.0.1:$port"
  log="$(_babel_ui_log)"
  if curl -s -o /dev/null "$url/api/status"; then
    echo "babel-ui 已在运行：$url"
  else
    # subshell + nohup: detached from this terminal, keeps running after you close it
    ( cd "$BABEL_UI_DIR" && BABEL_UI_PORT="$port" nohup "$(_babel_ui_python)" -u server.py >>"$log" 2>&1 & )
    for i in $(seq 1 50); do
      curl -s -o /dev/null "$url/api/status" && break
      sleep 0.2
    done
    if ! curl -s -o /dev/null "$url/api/status"; then
      echo "babel-ui 启动失败，日志最后几行（$log）："
      tail -n 20 "$log"
      return 1
    fi
    echo "babel-ui 已启动：$url（日志 $log）"
  fi
  browser="$(_babel_ui_cfg BABEL_UI_BROWSER "")"
  if [ "$browser" = none ]; then
    return 0
  elif [ -n "$browser" ]; then
    open -na "$browser" --args --new-window "$url" 2>/dev/null || open -a "$browser" "$url"
  elif [ -d "/Applications/Google Chrome.app" ]; then
    open -na "Google Chrome" --args --new-window "$url"
  elif command -v open >/dev/null; then
    open "$url"
  elif command -v xdg-open >/dev/null; then
    xdg-open "$url" >/dev/null 2>&1
  else
    echo "在浏览器里打开 $url"
  fi
}

babel-ui-stop() {
  local port pids host
  port="$(_babel_ui_cfg BABEL_UI_PORT 8765)"
  pids="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null)"
  if [ -n "$pids" ]; then
    # word-split on purpose: one pid per word
    if [ -n "${ZSH_VERSION:-}" ]; then kill ${=pids}; else kill $pids; fi && echo "babel-ui 已停止"
  else
    echo "babel-ui 没在运行"
  fi
  if [ "${1:-}" = --all ]; then
    host="$(_babel_ui_cfg BABEL_HOST babel)"
    ssh -o ControlPath="$HOME/.ssh/babel-ui-%C" -O exit "$host" 2>/dev/null && echo "已断开到 $host 的 SSH 连接"
  fi
}
