# Babel UI

一个只跑在你自己电脑上的 Slurm 集群面板，为 CMU Babel 做的：作业 / 日志 / GPU 利用率、历史作业、申请资源、各节点 GPU 占用、文件浏览与在线编辑、网页终端、作业通知。

集群上什么都不用装。所有数据都是本机 `ssh` 上去执行 `squeue` / `scontrol` / `sacct` / `sbatch --test-only` 等命令拿到的，权限和你自己登录集群完全一样。

## 安装

### 需要什么

- **macOS**（Linux 大部分功能也能用，见[其它系统](#其它系统)）
- **Python 3.10+**：`python3 -V` 看一下
- **能 ssh 上集群**：`~/.ssh/config` 里有一个 Host 指向登录节点。Babel 的话：

  ```
  Host babel
      HostName login.babel.cs.cmu.edu
      User 你的AndrewID
  ```

  先在终端里 `ssh babel` 确认能登上去。

### 步骤

```bash
git clone https://github.com/the-lord-of-stars/babel-ui.git
cd babel-ui
./install.sh
```

`install.sh` 会做三件事，重复运行也没关系：

1. 在项目里建 `.venv` 虚拟环境，装好依赖（`aiohttp`、`keyring`）；
2. 从 `.env.example` 生成 `.env` 配置文件（已有就不动）；
3. 在 `~/.zshrc`（bash 用户是 `~/.bash_profile` / `~/.bashrc`）末尾加一行 `source .../babel-ui.sh`，提供 `babel-ui` 命令。

然后**打开一个新终端**：

```bash
babel-ui             # 启动，并在新浏览器窗口打开 http://127.0.0.1:8765
babel-ui-stop        # 关闭
babel-ui-stop --all  # 关闭，并断开到集群的共享 ssh 连接
```

服务在后台运行，关掉终端窗口也不会停；日志在 `~/Library/Logs/babel-ui.log`。

### 第一次登录

打开页面后会自动跳到「终端」页，里面是 `ssh babel` 的密码 / Duo 提示。登录一次后左上角变绿，其它页开始自动刷新。

之后所有请求都复用这一条 ssh 连接（ControlMaster，socket 在 `~/.ssh/babel-ui-*`），不会反复登录。连接空闲 8 小时后自动关闭。

**自动登录（可选）**：点右上角 🔑 保存密码。密码存进系统钥匙串（服务名 `babel-ui`），不写入任何文件或环境变量，网页也读不回来。之后连接断开时会通过 `SSH_ASKPASS`（[askpass.py](askpass.py)）自动登录；遇到 Duo 会按 `BABEL_UI_DUO_OPTION` 回答（默认 1 = 推送），在手机上确认即可。自动登录失败一次就停，直到你在 🔑 里点「立即登录」或保存新密码，避免错误密码反复尝试把账号锁掉。

> 如果集群允许 SSH 密钥登录，更推荐 `ssh-copy-id babel`，连密码都不用存。

## 配置

所有设置都是环境变量，可以写在项目根目录的 `.env` 里（模板见 [.env.example](.env.example)）。shell 里已经设置的变量优先于 `.env`。改完 `babel-ui-stop && babel-ui` 重启生效。

| 变量 | 默认 | 说明 |
|---|---|---|
| `BABEL_HOST` | `babel` | `~/.ssh/config` 里的 Host 名字 |
| `BABEL_UI_PORT` | `8765` | 本地端口（只监听 127.0.0.1） |
| `BABEL_UI_NAME` | `Babel` | 页面标题和通知里显示的集群名 |
| `BABEL_UI_PERSIST` | `8h` | 共享 ssh 连接空闲多久后关闭（ssh 的 ControlPersist） |
| `BABEL_UI_DUO_OPTION` | `1` | 自动登录遇到 Duo 时回答的选项；留空表示不自动回答 |
| `BABEL_UI_PROTECT` | 空 | 文件页禁止删除 / 移动的额外路径，冒号分隔 |
| `BABEL_UI_PYTHON` | 空 | Python 解释器；空 = 项目的 `.venv`，没有就用 `python3` |
| `BABEL_UI_BROWSER` | 空 | `babel-ui` 用哪个浏览器打开（macOS 应用名，如 `Safari`）；空 = 有 Chrome 用 Chrome，否则系统默认；`none` = 不打开 |

不用 `babel-ui` 命令也可以直接跑：`.venv/bin/python server.py`。

### 用在别的集群

面板只依赖标准的 Slurm 命令，换集群一般只要改 `.env`：`BABEL_HOST` 指向那个集群的 ssh Host，`BABEL_UI_NAME` 改成它的名字；不是 Duo 的话把 `BABEL_UI_DUO_OPTION` 清空。

能提交的分区、QoS、卡型都是运行时从 `sacctmgr` / `scontrol` 读出来的，不用配置。

## 功能

- **作业**：`squeue -u $USER`，每 10 秒刷新；✕ 调 `scancel`（会先确认）；运行中的作业有「进入」按钮，`srun --overlap` 进作业所在节点的 shell，退出不影响作业。底部是你能用的分区的运行 / 排队数，其余分区折叠。
  - **点一行打开详情**：实时跟踪 stdout / stderr（增量读取，相当于 `tail -f`，可下载完整日志）；运行中的 GPU 作业会在节点上跑 `nvidia-smi`，显示每块卡的算力和显存利用率，利用率过低会提醒。
  - **系统通知**：作业开始运行、结束（完成 / 失败 / 超时等）时弹桌面通知。服务端每 30 秒检查一次，页面关着也会通知；勾选框可关闭。
- **历史**：`sacct` 最近 1 / 7 / 30 天的作业，含退出码、用时、资源。点一行看详情和日志。「重新提交」把 `cd 原目录 && 原 sbatch 命令` 放进终端但不回车——`sacct` 记录的命令丢了引号，需要你确认一下再按回车。
- **申请**：选分区 / 卡型 / 卡数 / CPU / 内存 / 时长：
  - 「预估开始时间」用 `sbatch --test-only` 问调度器，不会提交作业；
  - 「开交互式会话」：先提交一个 `sleep infinity` 的占位作业，开始运行后用 `srun --jobid --overlap --pty` 进计算节点的 shell（Babel 的 preempt 只允许 `sbatch`，`salloc` 会被拒）；exit、等待时 Ctrl-C 或终端断开都会自动 `scancel`；
  - 「复制 #SBATCH 头」复制对应的脚本头。

  分区列表只列你的 QoS 能提交的（从 `sacctmgr` 的 association 推出来），会自动带上 `--qos`；GPU 数为 0 时如果有对应的 CPU QoS（如 `preempt_cpu_qos`）会自动换用。
- **GPU**：`scontrol show node`，每 20 秒刷新。每块卡一个格子，空卡多的节点排前面；下拉框按分区筛选（你能用的带 ✓ 排在前面），顶部按卡型统计，点卡型再筛；你的作业所在节点名会高亮。"空闲"只算真正调度得上的卡，另外两种空卡单独显示：
  - **空闲但预留**（空心）：节点是 `PLANNED`，调度器已把空闲资源留给排队中的作业，短作业也许能 backfill 进去；
  - **卡空但缺 CPU**（斜纹）：卡空着但节点 CPU 或内存已分配完，申请不到。
- **文件**：点目录进入；行尾 ⬇ 下载（目录打包成 .tar.gz）；「上传」或直接拖进来（不会覆盖同名文件）；「分析占用」对当前目录跑 `du -d1` 画条形图；「终端 cd 到此」。
  - **浏览计算节点**：文件页标题旁的下拉框可以切到你正在运行的作业所在的计算节点（作业页每个运行中的作业也有「文件」按钮）。上传、下载、在线编辑、整理目录、分析占用都在那台节点上进行，用来看节点本地的 `/tmp`、`/scratch`、`/dev/shm`（登录节点和别的节点看不到，作业结束后不保证保留）。底层是 `srun --jobid=… --overlap` 在作业自己的资源里跑命令，不额外申请资源，也不依赖节点间的 ssh 密钥。家目录和 `/data` 是共享存储，两边看到的是同一份。多节点作业只看第一台节点。
    - 在节点和登录节点之间复制 / 剪切：命令在节点那一侧执行，所以两边路径都在共享存储上才行；节点本地的 `/tmp` 文件可以直接复制到家目录来抢救结果。两台不同节点之间不能直接复制。
    - 在节点的 `/tmp`、`/scratch`、`/dev/shm` 里可以删除和移动里面的东西（这些目录本身不行）；其余路径的保护规则和登录节点一样。
    - 「终端 cd 到此」在节点模式下会先 `srun --pty` 进入那个作业，再落到这个目录；作业结束后文件页会自动切回登录节点。
  - **在线编辑**：点文件用代码编辑器打开（按扩展名 / shebang 高亮），「保存」或 ⌘S 写回集群。写入是原子的（先写临时文件再 `mv`，保留原权限）；打开之后文件被别的程序改过的话，保存会提示冲突。二进制、非 UTF-8 或超过 2MB 的文件只提供下载。
  - **整理目录**：勾选后复制 / 剪切 / 重命名 / 删除，到目标目录点「粘贴到这里」；工具栏有新建文件夹 / 新建文件。粘贴不覆盖同名项（移动时跳过并提示，复制到同一目录自动加 `_copy` 后缀）。删除是永久的，会列出要删的项让你确认；服务端拒绝删除或移动顶层目录、你的主目录、`/xxx/你的用户名` 这类个人根目录和 `BABEL_UI_PROTECT` 里的路径。
- **终端**：完整的 ssh 会话（xterm.js），支持 vim / tmux / htop。

## 安全

- 只监听 `127.0.0.1`，并拒绝其它网页的跨站请求 / WebSocket。
- 密码只在你主动保存时存进系统钥匙串；否则认证完全交给你本机的 ssh。
- 申请资源、文件操作的参数在服务端校验后才拼进命令。

## 其它系统

- **Linux**：能用。通知用 `notify-send`；自动登录依赖 `keyring` 能找到的密钥环（GNOME Keyring / KWallet），没有的话不要保存密码，在终端里登录即可。浏览器用 `xdg-open` 打开。
- **Windows**：不支持（网页终端依赖 `pty`）。可以在 WSL 里跑。

## 卸载

```bash
babel-ui-stop --all
```

然后删掉 shell 配置里 `source .../babel-ui.sh` 那一行、项目目录，以及（如果保存过密码）钥匙串里服务名为 `babel-ui` 的条目。
