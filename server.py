#!/usr/bin/env python3
"""Local web UI for a Slurm cluster reached over ssh (built for CMU Babel).

Everything goes through your own `ssh` using a shared ControlMaster socket, so
you authenticate (password / Duo) once in the in-page terminal and the
dashboard calls reuse that connection. No credentials are stored.

    python3 server.py            # then open http://127.0.0.1:8765

Settings are environment variables, optionally kept in a `.env` file next to
this script (see .env.example); variables already set in the environment win.

Optionally save your password from the page (stored in the system keychain,
never on disk or in env); the server then logs in on its own via SSH_ASKPASS.
"""
import asyncio
import fcntl
import json
import os
import pty
import re
import shlex
import shutil
import signal
import struct
import sys
import tempfile
import termios
from pathlib import Path
from urllib.parse import quote, urlparse

import keyring
import keyring.errors
from aiohttp import WSMsgType, web

ROOT = Path(__file__).parent


def load_dotenv(path: Path):
    """Minimal .env reader: KEY=VALUE lines, # comments, optional quotes.
    Never overrides variables that are already set."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip().removeprefix("export ").strip()
        val = val.strip()
        if val[:1] in "\"'" and val[:1] and val.count(val[0]) >= 2:
            val = val[1:val.index(val[0], 1)]
        else:
            val = val.split(" #", 1)[0].strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            os.environ.setdefault(key, val)


load_dotenv(ROOT / ".env")

# ---- settings (all optional; documented in .env.example)
HOST = os.environ.get("BABEL_HOST") or "babel"               # ssh host alias from ~/.ssh/config
PORT = int(os.environ.get("BABEL_UI_PORT") or os.environ.get("PORT") or 8765)
NAME = os.environ.get("BABEL_UI_NAME") or "Babel"            # shown in the page and notifications
PERSIST = os.environ.get("BABEL_UI_PERSIST") or "8h"         # idle lifetime of the shared ssh connection
DUO_OPTION = os.environ.get("BABEL_UI_DUO_OPTION", "1")      # reply to Duo's "Passcode or option"; "" = don't
PROTECT = [p.rstrip("/") for p in os.environ.get("BABEL_UI_PROTECT", "").split(":") if p.startswith("/")]

STATIC = ROOT / "static"
ASKPASS = ROOT / "askpass.py"
KEY_SERVICE = "babel-ui"

SSH_BASE = [
    "ssh",
    "-o", "ControlMaster=auto",
    "-o", f"ControlPath={Path.home()}/.ssh/babel-ui-%C",
    "-o", f"ControlPersist={PERSIST}",
    "-o", "ServerAliveInterval=30",
]


# sshd caps sessions per multiplexed connection (MaxSessions, default 10) and
# terminals share that budget, so keep dashboard calls few at a time.
_slots = asyncio.Semaphore(3)


def job_arg(v) -> str | None:
    """Optional job id from a request; a job means "run this on that job's compute node"."""
    if v in (None, "", "login"):
        return None
    if not re.fullmatch(r"\d+", str(v)):
        raise ValueError("bad job id")
    return str(v)


def on_node(cmd: str, job: str | None) -> str:
    """Wrap a shell command so it runs inside a running job's allocation (on its first node).
    srun --overlap shares the job's resources instead of asking for new ones, so it also works
    on partitions that only allow sbatch; unlike ssh-ing to the node it needs no keys."""
    if not job:
        return cmd
    return f"srun --jobid={job} --overlap -N1 -n1 --quiet bash -c {shlex.quote(cmd)}"


def node_error(err: str, job: str | None) -> str:
    if job and re.search(r"Invalid job id|job has expired|Unable to create step|not in a running state|"
                         r"Requested nodes are busy|Job.*state", err):
        return f"作业 {job} 已经结束，或者还没开始运行，进不了它的计算节点"
    return err


async def run(cmd: str, timeout: float = 20, raw: bool = False, job: str | None = None):
    """Run a remote command over the shared connection; never prompts.

    Returns (code, stdout, stderr); stdout stays bytes when raw=True.
    With job=<id> it runs on that running job's compute node instead of the login node.
    """
    cmd = on_node(cmd, job)
    async with _slots:
        for attempt in range(3):
            code, out, err = await _run_once(cmd, timeout)
            if "Session open refused" not in err:
                break
            await asyncio.sleep(1 + attempt)
        return code, (out if raw else out.decode(errors="replace")), node_error(err, job)


def ssh_exec(cmd: str, job: str | None = None, **kw):
    return asyncio.create_subprocess_exec(
        *SSH_BASE, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", HOST, on_node(cmd, job), **kw)


async def _run_once(cmd: str, timeout: float) -> tuple[int, bytes, str]:
    proc = await ssh_exec(cmd, stdin=asyncio.subprocess.DEVNULL,
                          stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return 124, b"", "timeout"
    return proc.returncode, out, err.decode(errors="replace")


def same_origin(request: web.Request) -> bool:
    """Block other web pages from driving this local server (CSRF / WS hijack)."""
    origin = request.headers.get("Origin")
    if not origin:
        return True
    return urlparse(origin).netloc == request.headers.get("Host")


@web.middleware
async def guard(request, handler):
    if not same_origin(request):
        raise web.HTTPForbidden(text="bad origin")
    return await handler(request)


def fail(msg, status=502):
    return web.json_response({"error": msg.strip()[:500]}, status=status)


# ---------------------------------------------------------------- status / login
async def master_alive() -> bool:
    proc = await asyncio.create_subprocess_exec(
        *SSH_BASE, "-O", "check", HOST,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    return await proc.wait() == 0


def has_password() -> bool:
    return keyring.get_password(KEY_SERVICE, HOST) is not None


# Auto-login state. After a failure we stop trying until the user saves a new
# password or clicks retry, so a wrong password can't lock the account.
login = {"state": "idle", "error": ""}
_login_lock = asyncio.Lock()


async def auto_login() -> bool:
    async with _login_lock:
        if await master_alive():
            return True
        if login["state"] == "failed" or not has_password():
            return False
        login.update(state="running", error="")
        env = dict(os.environ,
                   SSH_ASKPASS=str(ASKPASS), SSH_ASKPASS_REQUIRE="force",
                   DISPLAY=os.environ.get("DISPLAY", ":0"), BABEL_UI_ACCOUNT=HOST,
                   BABEL_UI_DUO_OPTION=DUO_OPTION,
                   PATH=f"{Path(sys.executable).parent}:{os.environ.get('PATH', '')}")
        # stderr goes to a file: the backgrounded (-f) master inherits it, so a
        # pipe would never reach EOF.
        with tempfile.TemporaryFile() as errf:
            proc = await asyncio.create_subprocess_exec(
                *SSH_BASE, "-o", "ControlMaster=yes", "-o", "NumberOfPasswordPrompts=1",
                "-o", "ConnectTimeout=10", "-fN", HOST,
                stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
                stderr=errf, env=env, start_new_session=True,
            )
            try:
                # Generous timeout: a Duo push may be waiting on your phone.
                await asyncio.wait_for(proc.wait(), 90)
                errf.seek(0)
                err = errf.read().decode(errors="replace")
            except asyncio.TimeoutError:
                proc.kill()
                err = "timed out (Duo push not approved?)"
        if proc.returncode == 0 and await master_alive():
            login.update(state="ok", error="")
            return True
        login.update(state="failed", error=err.strip()[-300:] or f"ssh exited {proc.returncode}")
        return False


async def status(request):
    connected = await master_alive()
    saved = has_password()
    if not connected and saved and login["state"] not in ("failed", "running"):
        asyncio.ensure_future(auto_login())
    return web.json_response({"connected": connected, "host": HOST, "name": NAME, "has_password": saved,
                              "login": login["state"], "login_error": login["error"]})


async def set_password(request):
    pw = (await request.json()).get("password", "")
    if not pw:
        return fail("empty password", 400)
    keyring.set_password(KEY_SERVICE, HOST, pw)
    login.update(state="idle", error="")
    return web.json_response({"ok": True})


async def delete_password(request):
    try:
        keyring.delete_password(KEY_SERVICE, HOST)
    except keyring.errors.PasswordDeleteError:
        pass
    login.update(state="idle", error="")
    return web.json_response({"ok": True})


async def retry_login(request):
    login.update(state="idle", error="")
    return web.json_response({"ok": await auto_login(), **login})


# ---------------------------------------------------------------- queue
QUEUE_FMT = "%i|%P|%j|%T|%M|%l|%D|%C|%b|%R|%S|%V"
QUEUE_KEYS = ["id", "partition", "name", "state", "elapsed", "limit",
              "nodes", "cpus", "gres", "reason", "start", "submit"]


async def queue(request):
    code, out, err = await run(
        f'squeue -u "$USER" -h -o "{QUEUE_FMT}"; echo "@@"; '
        'squeue -h -t PD -o "%P" | sort | uniq -c; echo "@@"; '
        'squeue -h -t R -o "%P" | sort | uniq -c'
    )
    if code != 0:
        return fail(err or "ssh failed")
    mine_raw, pend_raw, run_raw = (out.split("@@\n") + ["", ""])[:3]
    mine = [dict(zip(QUEUE_KEYS, ln.split("|"))) for ln in mine_raw.splitlines() if ln]

    def counts(raw):
        d = {}
        for ln in raw.splitlines():
            m = re.match(r"\s*(\d+)\s+(\S+)", ln)
            if m:
                d[m.group(2)] = int(m.group(1))
        return d

    return web.json_response({"jobs": mine, "pending": counts(pend_raw), "running": counts(run_raw)})


async def cancel(request):
    jid = (await request.json()).get("id", "")
    if not re.fullmatch(r"\d+(_\d+)?", jid):
        return fail("bad job id", 400)
    code, out, err = await run(f"scancel {jid}")
    return web.json_response({"ok": code == 0, "error": err.strip()})


# ---------------------------------------------------------------- gpus
GRES_RE = re.compile(r"gpu(?::([A-Za-z0-9_.\-]+))?:(\d+)")


def parse_gres(s: str):
    m = GRES_RE.search(s or "")
    if not m:
        return None, 0
    return m.group(1) or "gpu", int(m.group(2))


def parse_used_idx(s: str):
    m = re.search(r"IDX:([\d,\-]+)", s or "")
    idx = set()
    if m:
        for part in m.group(1).split(","):
            if "-" in part:
                a, b = part.split("-")
                idx.update(range(int(a), int(b) + 1))
            elif part:
                idx.add(int(part))
    return idx


async def gpus(request):
    code, out, err = await run("scontrol show node -o", timeout=30)
    if code != 0:
        return fail(err or "ssh failed")
    nodes = []
    for ln in out.splitlines():
        kv = dict(re.findall(r"(\w+)=(\S*)", ln))
        gtype, total = parse_gres(kv.get("Gres", ""))
        if not total:
            continue
        _, used = parse_gres(kv.get("GresUsed", ""))
        if not used:
            m = re.search(r"gres/gpu=(\d+)", kv.get("AllocTRES", ""))
            used = int(m.group(1)) if m else 0
        idx = parse_used_idx(kv.get("GresUsed", ""))
        if not idx:
            idx = set(range(used))
        nodes.append({
            "name": kv.get("NodeName"),
            "type": gtype,
            "total": total,
            "used": used,
            "used_idx": sorted(idx),
            "state": kv.get("State", ""),
            "partitions": kv.get("Partitions", ""),
            "cpus": f'{kv.get("CPUAlloc", "?")}/{kv.get("CPUTot", "?")}',
            "mem_gb": f'{int(kv.get("AllocMem", 0)) // 1024}/{int(kv.get("RealMemory", 0)) // 1024}',
            # Idle GPUs on a node with no CPU/memory left can't actually be scheduled.
            "cpu_free": int(kv.get("CPUTot", 0)) - int(kv.get("CPUAlloc", 0)),
            "mem_free_gb": (int(kv.get("RealMemory", 0)) - int(kv.get("AllocMem", 0))) // 1024,
        })
    nodes.sort(key=lambda n: (n["type"], n["name"]))
    return web.json_response({"nodes": nodes})


# ---------------------------------------------------------------- files
def req_job(request, body=None):
    """The `job` parameter of a request (query string, or JSON body for POSTs)."""
    return job_arg(request.query.get("job") if body is None else body.get("job"))


async def ls(request):
    path = request.query.get("path", "")
    try:
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    target = shlex.quote(path) if path else '"$HOME"'
    # Only a failing `cd` is an error. find exits non-zero when an entry vanishes or is unreadable
    # mid-listing, which is routine in busy shared dirs like /tmp, so keep what it did list.
    code, out, err = await run(
        f'cd {target} 2>&1 || exit 2; pwd; '
        r"find . -maxdepth 1 -mindepth 1 -printf '%y|%s|%T@|%m|%u|%f\n' 2>/dev/null; true", job=job, timeout=40
    )
    if code != 0:
        return fail(err or out, 400)
    lines = out.splitlines()
    cwd, entries = lines[0], []
    for ln in lines[1:]:
        parts = ln.split("|", 5)
        if len(parts) == 6:
            t, size, mtime, mode, user, name = parts
            entries.append({"type": t, "size": int(size), "mtime": float(mtime),
                            "mode": mode, "user": user, "name": name})
    return web.json_response({"cwd": cwd, "entries": entries})


async def du(request):
    path = request.query.get("path", "")
    if not path:
        return fail("path required", 400)
    try:
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    code, out, err = await run(
        f"timeout 110 du -k -d1 -x {shlex.quote(path)} 2>/dev/null", timeout=120, job=job)
    rows = []
    for ln in out.splitlines():
        size, _, p = ln.partition("\t")
        if size.isdigit():
            rows.append({"path": p, "kb": int(size)})
    return web.json_response({"rows": rows, "partial": code != 0})


async def head(request):
    path = request.query.get("path", "")
    if not path:
        return fail("path required", 400)
    try:
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    code, out, err = await run(f"head -c 30000 -- {shlex.quote(path)}", job=job)
    return web.json_response({"text": out, "error": err.strip() if code else ""})


async def disk(request):
    # quota can hang on NFS; the remote `timeout` makes sure it dies on Babel too
    # (killing our local ssh client doesn't stop the remote process).
    try:
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    if job:  # on a compute node what matters is the node-local disk and RAM disk
        code, out, err = await run("timeout 10 df -h /tmp /dev/shm | awk 'NR>1'", job=job)
        return web.json_response({"text": out if code == 0 else err})
    code, out, err = await run('timeout 10 df -h "$HOME" | tail -1; echo "@@"; '
                               'timeout 10 quota -s 2>/dev/null | tail -n +3')
    return web.json_response({"text": out.replace("@@\n", "\n")})


# ---------------------------------------------------------------- account
_me_cache: dict = {}


async def me(request):
    """Who am I, and which partitions will accept my jobs (via my QoS)."""
    if _me_cache:
        return web.json_response(_me_cache)
    code, out, err = await run(
        'echo "$USER"; echo @@; '
        'sacctmgr -nP show assoc user="$USER" format=account,qos,defaultqos; echo @@; '
        'scontrol show partition -o; echo @@; '
        'sacctmgr -nP show qos format=name,maxtrespu,maxjobspu', timeout=30)
    if code != 0:
        return fail(err or "ssh failed")
    user, assoc, parts, qos = (out.split("@@\n") + ["", "", ""])[:4]
    account, default_qos, my_qos = "", "", set()
    for ln in assoc.splitlines():
        a, q, d = (ln.split("|") + ["", ""])[:3]
        account = account or a
        default_qos = default_qos or d
        my_qos.update(x for x in q.split(",") if x)
    limits = {}
    for ln in qos.splitlines():
        f = ln.split("|")
        if len(f) >= 3:
            limits[f[0]] = {"tres": f[1], "jobs": f[2]}
    usable = []
    for ln in parts.splitlines():
        kv = dict(re.findall(r"(\w+)=(\S*)", ln))
        allow = [q for q in kv.get("AllowQos", "").split(",") if q]
        match = default_qos if "ALL" in allow else next((q for q in allow if q in my_qos), "")
        if match:
            usable.append({"name": kv.get("PartitionName"), "qos": match,
                           "default_time": kv.get("DefaultTime"), "max_time": kv.get("MaxTime"),
                           "limit": limits.get(match)})
    _me_cache.update(user=user.strip(), account=account, qos=sorted(my_qos), partitions=usable)
    return web.json_response(_me_cache)


# ---------------------------------------------------------------- request resources
REQ_FIELDS = {
    "partition": r"[\w.\-]+", "qos": r"[\w.\-]*", "gpu_type": r"[\w.\-]*",
    "gpus": r"\d{1,2}", "cpus": r"\d{1,3}", "mem": r"\d{1,5}[MG]?", "time": r"[\d:\-]{1,14}",
}


def req_opts(d: dict) -> list[str]:
    for k, rx in REQ_FIELDS.items():
        if not re.fullmatch(rx, str(d.get(k, ""))):
            raise ValueError(f"bad {k}")
    opts = [f"--partition={d['partition']}"]
    if d["qos"]:
        opts.append(f"--qos={d['qos']}")
    if int(d["gpus"]):
        opts.append(f"--gres=gpu:{d['gpu_type'] + ':' if d['gpu_type'] else ''}{d['gpus']}")
    opts += [f"--cpus-per-task={d['cpus']}", f"--mem={d['mem']}", f"--time={d['time']}"]
    return opts


async def estimate(request):
    """sbatch --test-only: asks the scheduler when this would start, submits nothing."""
    try:
        opts = req_opts(await request.json())
    except ValueError as e:
        return fail(str(e), 400)
    code, out, err = await run(f"sbatch --test-only {' '.join(opts)} --wrap=true 2>&1", timeout=40)
    m = re.search(r"to start at (\S+).*?on nodes (\S+)", out)
    return web.json_response({"ok": bool(m), "start": m and m.group(1), "nodes": m and m.group(2),
                              "text": out.strip() or err.strip()})


# ---------------------------------------------------------------- job detail / logs / gpu
def expand_log_path(p: str, job: dict) -> str:
    """sacct keeps the unexpanded --output pattern (e.g. logs/%x-%j.log)."""
    if not p:
        return ""
    jid = job.get("id", "")
    base, _, idx = jid.partition("_")
    subs = {"j": jid, "J": jid, "A": base, "a": idx, "x": job.get("name", ""),
            "u": job.get("user", ""), "N": (job.get("nodes") or "").split(",")[0], "%": "%"}
    p = re.sub(r"%(\w|%)", lambda m: subs.get(m.group(1), m.group(0)), p)
    if not p.startswith("/") and job.get("workdir"):
        p = job["workdir"].rstrip("/") + "/" + p
    return p


async def job_info(request):
    jid = request.query.get("id", "")
    if not re.fullmatch(r"\d+(_\d+)?", jid):
        return fail("bad job id", 400)
    code, out, _ = await run(f"scontrol show job -o {jid} 2>/dev/null")
    if code == 0 and out.strip():
        kv = dict(re.findall(r"(\w+)=(\S*)", out))
        job = {"id": jid, "name": kv.get("JobName", ""), "state": kv.get("JobState", ""),
               "user": kv.get("UserId", "").split("(")[0], "nodes": kv.get("NodeList", ""),
               "workdir": kv.get("WorkDir", ""), "partition": kv.get("Partition", ""),
               "tres": kv.get("AllocTRES") or kv.get("ReqTRES", ""),
               "runtime": kv.get("RunTime", ""), "limit": kv.get("TimeLimit", ""),
               "command": kv.get("Command", ""), "stdout": kv.get("StdOut", ""),
               "stderr": kv.get("StdErr", ""), "reason": kv.get("Reason", "")}
    else:
        code, out, err = await run(
            f"sacct -j {jid} -X -n -P -o JobID,JobName,State,User,NodeList,WorkDir,Partition,"
            "AllocTRES,Elapsed,Timelimit,StdOut,StdErr,SubmitLine")
        f = out.strip().split("\n")[0].split("|", 12) if out.strip() else []
        if len(f) < 13:
            return fail("job not found", 404)
        job = dict(zip(["id", "name", "state", "user", "nodes", "workdir", "partition", "tres",
                        "runtime", "limit", "stdout", "stderr", "command"], f))
    job["stdout"] = expand_log_path(job["stdout"], job)
    job["stderr"] = expand_log_path(job["stderr"], job)
    if job["stderr"] == job["stdout"]:
        job["stderr"] = ""
    return web.json_response(job)


async def tail(request):
    """Incremental file read: first call (offset<0) returns the last 64KB."""
    path = request.query.get("path", "")
    if not path.startswith("/"):
        return fail("absolute path required", 400)
    offset = int(request.query.get("offset", "-1"))
    code, out, err = await run(
        f"f={shlex.quote(path)}; [ -r \"$f\" ] || {{ echo -1; echo 0; exit 0; }}; "
        "s=$(stat -c %s -- \"$f\"); echo \"$s\"; "
        f"o={offset}; if [ \"$o\" -lt 0 ] || [ \"$o\" -gt \"$s\" ]; then "
        "o=$(( s > 65536 ? s - 65536 : 0 )); fi; echo \"$o\"; "
        "tail -c +$((o + 1)) -- \"$f\" | head -c 262144", raw=True)
    if code != 0:
        return fail(err, 502)
    size, start, data = (out.split(b"\n", 2) + [b"", b""])[:3]
    size, start = int(size or -1), int(start or 0)
    return web.json_response({"exists": size >= 0, "size": size, "start": start,
                              "next": start + len(data), "text": data.decode(errors="replace")})


async def job_gpu(request):
    """nvidia-smi inside the job's allocation (only its own GPUs are visible)."""
    jid = request.query.get("id", "")
    if not re.fullmatch(r"\d+(_\d+)?", jid):
        return fail("bad job id", 400)
    code, out, err = await run(
        f"timeout 40 srun --jobid={jid} --overlap -N1 -n1 --quiet nvidia-smi "
        "--query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits",
        timeout=45)
    if code != 0:
        return fail(err or out or "srun failed")
    gpus = []
    for ln in out.splitlines():
        f = [x.strip() for x in ln.split(",")]
        if len(f) == 5 and f[0].isdigit():
            gpus.append({"index": int(f[0]), "name": f[1], "util": int(f[2]),
                         "mem_used": int(f[3]), "mem_total": int(f[4])})
    return web.json_response({"gpus": gpus})


# ---------------------------------------------------------------- history
HIST_KEYS = ["id", "name", "partition", "state", "exit", "elapsed", "start", "end",
             "tres", "nodes", "workdir", "submit_line"]


async def history(request):
    days = int(request.query.get("days", "7"))
    code, out, err = await run(
        f"sacct -X -n -P -S now-{max(1, min(days, 90))}days "
        "-o JobID,JobName,Partition,State,ExitCode,Elapsed,Start,End,AllocTRES,NodeList,WorkDir,SubmitLine",
        timeout=40)
    if code != 0:
        return fail(err)
    jobs = [dict(zip(HIST_KEYS, ln.split("|", 11))) for ln in out.splitlines() if ln.count("|") >= 11]
    return web.json_response({"jobs": jobs[::-1]})


# ---------------------------------------------------------------- download / upload
async def download(request):
    path = request.query.get("path", "")
    if not path.startswith("/"):
        return fail("absolute path required", 400)
    try:
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    q = shlex.quote(path)
    code, out, err = await run(f"test -d {q} && echo d || (test -r {q} && echo f || echo x)", job=job)
    kind = out.strip()
    if code != 0 or kind not in ("d", "f"):
        return fail(err if code != 0 else "not readable", 404)
    name = path.rstrip("/").rsplit("/", 1)[-1] or "root"
    if kind == "d":
        parent = path.rstrip("/").rsplit("/", 1)[0] or "/"
        cmd, name = f"tar czf - -C {shlex.quote(parent)} {shlex.quote(name)}", name + ".tar.gz"
    else:
        cmd = f"cat -- {q}"
    resp = web.StreamResponse(headers={
        "Content-Type": "application/octet-stream",
        "Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"})
    await resp.prepare(request)
    proc = await ssh_exec(cmd, job=job, stdin=asyncio.subprocess.DEVNULL,
                          stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    try:
        while chunk := await proc.stdout.read(1 << 16):
            await resp.write(chunk)
    finally:
        if proc.returncode is None:
            proc.kill()
        await proc.wait()
    await resp.write_eof()
    return resp


async def upload(request):
    """Stream multipart files into `dir`; never overwrites (noclobber)."""
    d = request.query.get("dir", "")
    if not d.startswith("/"):
        return fail("absolute dir required", 400)
    try:
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    results = []
    reader = await request.multipart()
    while part := await reader.next():
        name = (part.filename or "").replace("\\", "/").rsplit("/", 1)[-1]
        if not name or name in (".", ".."):
            continue
        target = d.rstrip("/") + "/" + name
        proc = await ssh_exec(f"set -C; cat > {shlex.quote(target)}", job=job,
                              stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL,
                              stderr=asyncio.subprocess.PIPE)
        size = 0
        try:
            while chunk := await part.read_chunk(1 << 16):
                size += len(chunk)
                proc.stdin.write(chunk)
                await proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        proc.stdin.close()
        err = (await proc.stderr.read()).decode(errors="replace").strip()
        await proc.wait()
        results.append({"name": name, "size": size, "ok": proc.returncode == 0,
                        "error": "同名文件已存在" if "exist" in err else node_error(err, job)})
    return web.json_response({"results": results})


# ---------------------------------------------------------------- edit files
EDIT_MAX = 2 * 1024 * 1024


def check_path(p) -> str:
    if not isinstance(p, str) or not p.startswith("/") or "\0" in p:
        raise ValueError("需要绝对路径")
    if any(seg in (".", "..") for seg in p.split("/")):
        raise ValueError("路径里不能有 . 或 ..")
    return p.rstrip("/") or "/"


def check_name(n) -> str:
    if not isinstance(n, str) or not n or n in (".", "..") or "/" in n or "\0" in n or len(n) > 255:
        raise ValueError(f"名字不合法：{n!r}")
    return n


async def read_file(request):
    """Text content for the editor, plus a version stamp for conflict checks."""
    try:
        path = check_path(request.query.get("path", ""))
        job = req_job(request)
    except ValueError as e:
        return fail(str(e), 400)
    code, out, err = await run(
        f"f={shlex.quote(path)}; stat -L -c '%y|%s|%F' -- \"$f\" || exit 4; "
        f"[ -d \"$f\" ] || head -c {EDIT_MAX + 1} -- \"$f\"", raw=True, job=job)
    if code != 0:
        return fail(err or "读取失败", 404)
    meta, _, data = out.partition(b"\n")
    mtime, size, kind = (meta.decode(errors="replace").split("|") + ["", ""])[:3]
    resp = {"version": f"{mtime}|{size}", "size": int(size or 0), "kind": kind}
    if "directory" in kind:
        return fail("这是目录", 400)
    if int(size or 0) > EDIT_MAX:
        return web.json_response({**resp, "editable": False, "reason": "文件超过 2MB"})
    if b"\0" in data[:8192]:
        return web.json_response({**resp, "editable": False, "reason": "二进制文件"})
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return web.json_response({**resp, "editable": False, "reason": "不是 UTF-8 文本"})
    return web.json_response({**resp, "editable": True, "text": text})


async def write_file(request):
    """Atomic save (temp file + mv, keeping permissions). Refuses with 409 if the
    file changed since `version` was read, unless force=true."""
    body = await request.json()
    try:
        path = check_path(body.get("path"))
        job = req_job(request, body)
    except ValueError as e:
        return fail(str(e), 400)
    data = body.get("text", "").encode("utf-8")
    if len(data) > EDIT_MAX:
        return fail("内容超过 2MB", 400)
    expect = "" if body.get("force") else body.get("version", "")
    script = (
        f"f={shlex.quote(path)}; t=$(readlink -f -- \"$f\") || exit 4; "
        f"e={shlex.quote(expect)}; "
        "if [ -n \"$e\" ]; then c=$(stat -c '%y|%s' -- \"$t\" 2>/dev/null); "
        "[ \"$c\" = \"$e\" ] || { cat >/dev/null; echo \"conflict|$c\"; exit 3; }; fi; "
        "tmp=\"$t.babel-ui.$$\"; cat > \"$tmp\" || { rm -f \"$tmp\"; exit 5; }; "
        "chmod --reference=\"$t\" \"$tmp\" 2>/dev/null; "
        "mv -f -- \"$tmp\" \"$t\" && stat -c '%y|%s' -- \"$t\"")
    proc = await ssh_exec(script, job=job, stdin=asyncio.subprocess.PIPE,
                          stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(data), 60)
    except asyncio.TimeoutError:
        proc.kill()
        return fail("保存超时")
    out = out.decode(errors="replace").strip()
    if proc.returncode == 3:
        return web.json_response({"ok": False, "conflict": True}, status=409)
    if proc.returncode != 0:
        return fail(node_error(err.decode(errors="replace"), job) or f"保存失败（{proc.returncode}）")
    return web.json_response({"ok": True, "version": out})


# ---------------------------------------------------------------- file operations
_home: dict = {}


async def remote_home() -> str:
    if "home" not in _home:
        _, out, _ = await run('echo "$HOME"; echo "$USER"')
        h, u = (out.split("\n") + ["", ""])[:2]
        _home.update(home=h.strip(), user=u.strip())
    return _home["home"]


NODE_SCRATCH = ("/tmp", "/scratch", "/dev/shm")   # node-local disks: fair game on a compute node


async def check_removable(p: str, job: str | None = None):
    """Never delete/move top-level dirs, your home, a per-user root like /data/user_data/$USER,
    anything listed in BABEL_UI_PROTECT, or a parent of any of those.
    On a compute node, items inside /tmp, /scratch and /dev/shm are allowed (not those dirs themselves)."""
    home = await remote_home()
    guarded = [home, *PROTECT]
    scratch = bool(job) and any(p.startswith(r + "/") for r in NODE_SCRATCH)
    if ((p.count("/") <= 2 and not scratch) or p.rsplit("/", 1)[-1] == _home["user"]
            or any(p == g or g.startswith(p + "/") for g in guarded)):
        raise ValueError(f"为安全起见，不允许删除或移动 {p}")


def parent_of(p: str) -> str:
    return p.rsplit("/", 1)[0] or "/"


def copy_name(name: str, taken: set) -> str:
    stem, dot, ext = name.rpartition(".")
    if not stem:  # no extension, or a dotfile like .bashrc
        stem, dot, ext = name, "", ""
    for i in range(1, 1000):
        cand = f"{stem}_copy{i if i > 1 else ''}{dot}{ext}"
        if cand not in taken:
            return cand
    raise ValueError("找不到可用的副本名")


async def fs_op(request):
    b = await request.json()
    op = b.get("op")
    q = shlex.quote
    skipped, timeout = [], 30
    try:
        job = req_job(request, b)
        if op in ("mkdir", "touch"):
            target = check_path(b.get("dir")) + "/" + check_name(b.get("name"))
            cmd = f"mkdir -- {q(target)}" if op == "mkdir" else f"set -C; : > {q(target)}"
        elif op == "rename":
            src = check_path(b.get("path"))
            await check_removable(src, job)
            dst = parent_of(src) + "/" + check_name(b.get("name"))
            cmd = (f"[ -e {q(dst)} ] && {{ echo '已存在同名项' >&2; exit 1; }}; "
                   f"mv -- {q(src)} {q(dst)}")
        elif op in ("move", "copy"):
            dest = check_path(b.get("dest"))
            srcs = [check_path(p) for p in b.get("paths", [])]
            lcode, listing, lerr = await run(f"ls -A -- {q(dest)}", job=job)
            if lcode != 0:
                return fail(lerr.strip() or "读取目标目录失败", 400)
            taken = set(listing.splitlines())
            parts = []
            for s in srcs:
                if dest == s or dest.startswith(s + "/"):
                    raise ValueError(f"不能把 {s} 放进它自己里面")
                name = s.rsplit("/", 1)[-1]
                if op == "move":
                    await check_removable(s, job)
                    if parent_of(s) == dest:
                        continue
                    if name in taken:
                        skipped.append(name)
                        continue
                    t = name
                    parts.append(f"mv -- {q(s)} {q(dest + '/' + t)}")
                else:
                    t = copy_name(name, taken) if name in taken else name
                    parts.append(f"cp -a -- {q(s)} {q(dest + '/' + t)}")
                taken.add(t)
            if not parts:
                return web.json_response({"ok": True, "skipped": skipped})
            cmd, timeout = "set -e; " + "; ".join(parts), 600
        elif op == "delete":
            srcs = [check_path(p) for p in b.get("paths", [])]
            for s in srcs:
                await check_removable(s, job)
            if not srcs:
                return fail("没有选中任何项", 400)
            cmd, timeout = "rm -rf -- " + " ".join(q(s) for s in srcs), 600
        else:
            return fail("unknown op", 400)
    except ValueError as e:
        return fail(str(e), 400)
    code, out, err = await run(f"timeout {timeout} bash -c {q(cmd)}", timeout=timeout + 20, job=job)
    if code != 0:
        return fail(err.strip() or out.strip() or f"操作失败（{code}）", 400)
    return web.json_response({"ok": True, "skipped": skipped})


# ---------------------------------------------------------------- notifications
async def mac_notify(title: str, body: str):
    """Desktop notification: osascript on macOS, notify-send on Linux, else nothing."""
    if shutil.which("osascript"):
        args = ["osascript", "-e", "on run argv",
                "-e", 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"',
                "-e", "end run", title, body]
    elif shutil.which("notify-send"):
        args = ["notify-send", title, body]
    else:
        return
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    await proc.wait()


async def watch_jobs(app):
    """Poll my queue; notify on PENDING→RUNNING and when a job leaves the queue."""
    seen: dict[str, tuple[str, str]] | None = None
    while True:
        await asyncio.sleep(30)
        if not app["notify"] or not await master_alive():
            continue
        code, out, _ = await run('squeue -u "$USER" -h -o "%i|%j|%T"')
        if code != 0:
            continue
        now = {}
        for ln in out.splitlines():
            f = ln.split("|", 2)
            if len(f) == 3:
                now[f[0]] = (f[1], f[2])
        if seen is not None:
            for jid, (name, state) in now.items():
                if state == "RUNNING" and seen.get(jid, ("", ""))[1] != "RUNNING":
                    await mac_notify(f"{NAME}：作业开始运行", f"{name} ({jid})")
            gone = [j for j in seen if j not in now]
            if gone:
                _, acct, _ = await run(f"sacct -j {','.join(gone)} -X -n -P -o JobID,JobName,State,ExitCode,Elapsed")
                for ln in acct.splitlines():
                    f = ln.split("|")
                    if len(f) == 5 and f[0] in gone:
                        ok = f[2].startswith("COMPLETED")
                        await mac_notify(f"{NAME}：作业{'完成' if ok else '结束：' + f[2].split()[0]}",
                                         f"{f[1]} ({f[0]}) · 用时 {f[4]} · 退出码 {f[3]}")
        seen = now


async def notify_cfg(request):
    if request.method == "POST":
        body = await request.json()
        if "on" in body:
            request.app["notify"] = bool(body["on"])
        if body.get("test"):
            await mac_notify(f"{NAME} UI", "通知已开启 ✓")
    return web.json_response({"on": request.app["notify"]})


async def start_watch(app):
    app["watch"] = asyncio.create_task(watch_jobs(app))


async def stop_watch(app):
    app["watch"].cancel()


# ---------------------------------------------------------------- terminal
async def terminal(request):
    ws = web.WebSocketResponse(heartbeat=30)
    await ws.prepare(request)
    if has_password() and not await master_alive():
        # Let the saved password open the shared connection first so the
        # terminal rides on it instead of prompting.
        await ws.send_bytes("正在用已保存的密码登录…\r\n".encode())
        await auto_login()

    pid, fd = pty.fork()
    if pid == 0:
        # ssh forwards TERM to Babel; xterm.js is xterm-compatible. Set it here so
        # clear/vim/htop work even when the server was started without a TERM.
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        os.execvp(SSH_BASE[0], SSH_BASE + ["-tt", HOST])
    request.app["terms"].add(pid)
    loop = asyncio.get_running_loop()
    os.set_blocking(fd, False)

    def on_output():
        try:
            data = os.read(fd, 65536)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if not data:
            loop.remove_reader(fd)
            asyncio.ensure_future(ws.close())
            return
        asyncio.ensure_future(ws.send_bytes(data))

    loop.add_reader(fd, on_output)
    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            m = json.loads(msg.data)
            if m["t"] == "i":
                os.write(fd, m["d"].encode())
            elif m["t"] == "r":
                fcntl.ioctl(fd, termios.TIOCSWINSZ,
                            struct.pack("HHHH", m["rows"], m["cols"], 0, 0))
    finally:
        try:
            loop.remove_reader(fd)
        except Exception:
            pass
        request.app["terms"].discard(pid)
        os.close(fd)   # hangs up the pty, which already tells ssh to quit
        # Never wait for the child here: if ssh ignores the hangup (e.g. stuck at a password
        # prompt) a blocking waitpid freezes the whole event loop and with it the whole panel.
        asyncio.ensure_future(reap(pid))
    return ws


async def reap(pid: int):
    """Get rid of a terminal's ssh without blocking: HUP first (a ControlMaster then lingers in
    the background and keeps the shared connection), then TERM, then KILL for one that won't go."""
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
        deadline = loop.time() + 3
        while loop.time() < deadline:
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return
            if done:
                return
            await asyncio.sleep(0.2)


async def kill_terms(app):
    """Don't leave ssh terminal sessions behind (they eat MaxSessions)."""
    for pid in list(app["terms"]):
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass


async def index(request):
    return web.FileResponse(STATIC / "index.html")


def main():
    # Editor saves arrive as JSON up to EDIT_MAX of text (aiohttp's default cap is 1MB).
    app = web.Application(middlewares=[guard], client_max_size=4 * EDIT_MAX)
    app["terms"] = set()
    app["notify"] = True
    app.on_startup.append(start_watch)
    app.on_shutdown.append(kill_terms)
    app.on_cleanup.append(stop_watch)
    app.add_routes([
        web.get("/api/me", me),
        web.post("/api/estimate", estimate),
        web.get("/api/job", job_info),
        web.get("/api/tail", tail),
        web.get("/api/job/gpu", job_gpu),
        web.get("/api/history", history),
        web.get("/api/download", download),
        web.post("/api/upload", upload),
        web.get("/api/read", read_file),
        web.post("/api/write", write_file),
        web.post("/api/fs", fs_op),
        web.get("/api/notify", notify_cfg),
        web.post("/api/notify", notify_cfg),
        web.get("/", index),
        web.get("/api/status", status),
        web.post("/api/password", set_password),
        web.delete("/api/password", delete_password),
        web.post("/api/login", retry_login),
        web.get("/api/queue", queue),
        web.post("/api/cancel", cancel),
        web.get("/api/gpus", gpus),
        web.get("/api/ls", ls),
        web.get("/api/du", du),
        web.get("/api/head", head),
        web.get("/api/disk", disk),
        web.get("/ws/term", terminal),
    ])
    print(f"{NAME} UI on http://127.0.0.1:{PORT}  (ssh host: {HOST})")
    web.run_app(app, host="127.0.0.1", port=PORT, print=None)


if __name__ == "__main__":
    main()
