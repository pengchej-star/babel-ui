#!/usr/bin/env bash
# One-time setup: .venv with dependencies, .env from the template, and the
# `babel-ui` / `babel-ui-stop` commands in your shell config. Safe to re-run.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
  echo "需要 Python 3.10 或更新版本（当前：$("$PY" -V 2>&1 || echo 没找到 $PY)）。"
  echo "可以用 PYTHON=/path/to/python3 ./install.sh 指定解释器。"
  exit 1
fi

echo "==> 准备虚拟环境 .venv 并安装依赖"
[ -x .venv/bin/python ] || "$PY" -m venv .venv
.venv/bin/python -m pip install -q --upgrade pip
.venv/bin/python -m pip install -q -r requirements.txt

if [ -f .env ]; then
  echo "==> 已有 .env，保留不动"
else
  cp .env.example .env
  echo "==> 已从 .env.example 生成 .env（需要的话改里面的设置）"
fi

case "$(basename "${SHELL:-}")" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) if [ "$(uname)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
  *)    RC="" ;;
esac
LINE="source \"$DIR/babel-ui.sh\""
if [ -z "$RC" ]; then
  echo "==> 没认出你的 shell，请手动把这一行加进 shell 配置文件："
  echo "    $LINE"
elif grep -qF "$LINE" "$RC" 2>/dev/null; then
  echo "==> $RC 里已经有 babel-ui 命令了"
else
  printf '\n# babel-ui: `babel-ui` 启动面板，`babel-ui-stop` 关闭\n%s\n' "$LINE" >> "$RC"
  echo "==> 已把 babel-ui 命令加入 $RC"
fi

HOST="$(set -a; . ./.env >/dev/null 2>&1; printf '%s' "${BABEL_HOST:-babel}")"
if ! grep -qiE "^[[:space:]]*Host([[:space:]].*)?[[:space:]]$HOST([[:space:]]|\$)" "$HOME/.ssh/config" 2>/dev/null; then
  cat <<EOF

注意：~/.ssh/config 里没找到 "Host $HOST"。面板通过 ssh $HOST 连接集群，请加上类似这样的配置
（Babel 的例子，User 换成你的 Andrew ID）：

    Host $HOST
        HostName login.babel.cs.cmu.edu
        User 你的AndrewID

或者在 .env 里把 BABEL_HOST 改成你已有的 Host 名字。
EOF
fi

cat <<EOF

完成。打开一个新终端（或运行 source ${RC:-你的shell配置}），然后：

    babel-ui         # 启动并在浏览器打开
    babel-ui-stop    # 关闭

EOF
