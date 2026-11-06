#!/usr/bin/env python3
"""Runs the Vita build on the console by itself and brings the log back (vitacompanion: FTP on 1337, commands on 1338).

    vitarun.py find                      look for the Vita on the LAN (port 1338 open); the address goes to tools/.vita_ip
    vitarun.py deploy                    build/flipendo.self -> ux0:app/FLPD00001/eboot.bin (the installed app, files kept)
                                         (VITA_APP=hp2 in front of any command: the flipendo2 app, FLPD00002, ux0:data/flipendo2)
    vitarun.py run <scenario> [--deploy] run a scenario (tools/bench/<name>.txt), wait for it, fetch the log, summarise
    vitarun.py bench <label> [--deploy]  slot0 + slot1, the numbers appended to tools/bench/results.txt
    vitarun.py summary <log>             the per-segment table of a log made with VITA_BENCH=1
    vitarun.py cmd "<command>"           send a vitacompanion command (launch / quit / press ... / screen on)
    vitarun.py get <remote> <local>      fetch a file (ux0:data/flipendo/flipendo.log ...)
    vitarun.py clean                     remove env.txt / args.txt (after a run that lost the Vita)

A scenario file: '#' comments, 'timeout=<s>', 'arg=<engine argument>', 'env=<NAME>=<value>'. The engine reads them from
ux0:data/flipendo/args.txt and env.txt (vita_main.cpp); they are deleted again after the run, so a normal start is unchanged.
The scenario should end the game itself (HP1_EXEC '...;<t>:exit'); the run also ends when the log stops growing.
Standard library only.
"""
import ftplib
import io
import os
import re
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
VITA_DIR = os.path.dirname(HERE)
IP_FILE = os.path.join(HERE, ".vita_ip")
# VITA_APP=hp2: Chamber of Secrets, the flipendo2 app (~/flipendo2: build/flipendo2.self, FLPD00002, ux0:data/flipendo2)
HP2 = os.environ.get("VITA_APP", "") == "hp2"
TITLE_ID = "FLPD00002" if HP2 else "FLPD00001"
DATA = "ux0:data/flipendo2" if HP2 else "ux0:data/flipendo"
SELF = (os.path.join(os.path.dirname(os.path.dirname(VITA_DIR)), "flipendo2", "build", "flipendo2.self") if HP2
        else os.path.join(VITA_DIR, "build", "flipendo.self"))
LOGS = os.path.join(os.path.dirname(VITA_DIR), "logs")
STALL = 60   # seconds without the log growing that end a run (scenario 'stall=')


def vita_ip():
    if os.environ.get("VITA_IP"):
        return os.environ["VITA_IP"]
    if os.path.exists(IP_FILE):
        return open(IP_FILE).read().strip()
    sys.exit("No Vita address: run 'vitarun.py find' or set VITA_IP")


def port_open(ip, port, timeout=0.4):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def find():
    # the Windows host's Wi-Fi/Ethernet networks: try 192.168.x.0/24 networks seen by ipconfig, else 192.168.0/1
    nets = set()
    try:
        out = os.popen("/mnt/c/Windows/System32/ipconfig.exe 2>/dev/null").read()
        for m in re.finditer(r"(192\.168\.\d+)\.\d+", out):
            nets.add(m.group(1))
    except Exception:
        pass
    if not nets:
        nets = {"192.168.0", "192.168.1"}
    candidates = [f"{n}.{i}" for n in sorted(nets) for i in range(1, 255)]
    with ThreadPoolExecutor(max_workers=64) as pool:
        hits = [ip for ip, ok in zip(candidates, pool.map(lambda ip: port_open(ip, 1338), candidates)) if ok]
    if not hits:
        sys.exit("No Vita found (vitacompanion running? Vita on the same Wi-Fi and awake?)")
    ip = hits[0]
    open(IP_FILE, "w").write(ip + "\n")
    print("Vita at", ip, "(others: %s)" % hits[1:] if len(hits) > 1 else "")
    return ip


def cmd(command, wait=1.0):
    ip = vita_ip()
    s = socket.create_connection((ip, 1338), timeout=10)
    s.sendall((command.strip() + "\n").encode())
    s.settimeout(wait)
    reply = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            reply += chunk
    except socket.timeout:
        pass
    s.close()
    return reply.decode(errors="replace").strip()


def ftp():
    f = ftplib.FTP()
    f.connect(vita_ip(), 1337, timeout=30)
    f.login()
    f.set_pasv(True)
    return f


def put_bytes(data, remote):
    f = ftp()
    f.storbinary("STOR /" + remote, io.BytesIO(data))
    f.quit()


def put_file(local, remote):
    f = ftp()
    with open(local, "rb") as fh:
        f.storbinary("STOR /" + remote, fh, blocksize=256 * 1024)
    f.quit()


def get_file(remote, local):
    f = ftp()
    with open(local, "wb") as fh:
        f.retrbinary("RETR /" + remote, fh.write, blocksize=256 * 1024)
    f.quit()


def size(remote):
    try:
        f = ftp()
        f.voidcmd("TYPE I")
        n = f.size("/" + remote)
        f.quit()
        return n
    except Exception:
        return None


def delete(remote):
    try:
        f = ftp()
        f.delete("/" + remote)
        f.quit()
    except Exception:
        pass


def deploy():
    local = SELF
    cmd("quit " + TITLE_ID)
    time.sleep(2)
    t = time.time()
    put_file(local, f"ux0:app/{TITLE_ID}/eboot.bin")
    print("eboot.bin uploaded: %.1f MB in %.1f s" % (os.path.getsize(local) / 1e6, time.time() - t))


def read_scenario(name):
    path = name if os.path.exists(name) else os.path.join(HERE, "bench", name + ".txt")
    timeout, args, env = 300, [], []
    global STALL
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        if key == "timeout":
            timeout = int(value)
        elif key == "stall":
            STALL = int(value)
        elif key == "arg":
            args.append(value)
        elif key == "env":
            env.append(value)
    return os.path.splitext(os.path.basename(path))[0], timeout, args, env


def run(name, do_deploy=False):
    scenario, timeout, args, env = read_scenario(name)
    if do_deploy:
        deploy()
    else:
        cmd("quit " + TITLE_ID)
        time.sleep(2)
    cmd("screen on")
    put_bytes(("\n".join(env) + "\n").encode(), f"{DATA}/env.txt")
    put_bytes(("\n".join(args) + "\n").encode(), f"{DATA}/args.txt")
    delete(f"{DATA}/flipendo.log")
    print("launch:", cmd("launch " + TITLE_ID))
    start = time.time()
    last_size, last_change = -1, time.time()
    last_seen = time.time()
    lost = False
    try:
        while time.time() - start < timeout:
            time.sleep(5)
            n = size(f"{DATA}/flipendo.log")
            if n is None and not port_open(vita_ip(), 1338, 2.0):
                if time.time() - last_seen > 60:
                    lost = True
                    print("  the Vita has not answered for a minute: off the network (asleep? crashed?)")
                    break
            else:
                last_seen = time.time()
            if n != last_size:
                last_size, last_change = n, time.time()
            elif n and time.time() - last_change > STALL and time.time() - start > 40:
                break   # the game is gone (exit) or hangs: the log has stopped growing
            print("  %3.0f s: log %s bytes" % (time.time() - start, n), flush=True)
    finally:
        try:
            cmd("quit " + TITLE_ID)
            time.sleep(1)
            delete(f"{DATA}/env.txt")
            delete(f"{DATA}/args.txt")
        except OSError as e:
            print("  could not reach the Vita to clean up:", e, "(env.txt/args.txt may still be there: 'vitarun.py clean')")
    if lost:
        sys.exit(1)
    os.makedirs(LOGS, exist_ok=True)
    local = os.path.join(LOGS, time.strftime(f"bench-{scenario}-%m%d-%H%M%S.log"))
    get_file(f"{DATA}/flipendo.log", local)
    print("log:", local)
    summary(local)
    return local


def segment_table(path):
    """[(segment name, avg ms, avg fps, avg engine, avg picture, rows)] of a VITA_BENCH log"""
    rows_by = []
    cur = ["start", []]
    for line in open(path, errors="replace"):
        m = re.search(r"HP1 exec t=[\d.]+: (.*)", line)
        if m:
            rows_by.append(cur)
            cur = [m.group(1)[:40], []]
            continue
        if "VitaBench:" in line:
            g = lambda pat: float(re.search(pat, line).group(1))
            try:
                cur[1].append((g(r"FPS [\d.]+  min [\d.]+  ([\d.]+) ms"), g(r"FPS ([\d.]+)"), g(r"engine ([\d.]+)"), g(r"picture ([\d.]+)")))
            except AttributeError:
                pass
    rows_by.append(cur)
    out = []
    for name, rows in rows_by:
        if len(rows) > 2:
            rows = rows[1:]
        if rows:
            n = len(rows)
            out.append((name, sum(r[0] for r in rows) / n, sum(r[1] for r in rows) / n, sum(r[2] for r in rows) / n, sum(r[3] for r in rows) / n))
    return out


def bench(label, do_deploy=False):
    """fire1 (Lev2_Fire1: stand, turn) and slot1 (the broom circling: two halves): the four numbers into bench/results.txt"""
    if do_deploy:
        deploy()
    results = []
    for slot in ("fire1", "slot1"):
        log = run(slot)
        segs = [s for s in segment_table(log) if s[0].startswith("@get harry0")]
        results += [(slot + (("/stand" if i == 0 else "/turn") if slot == "fire1" else ("/circle" if i == 0 else "/circle2")), s[1], s[2], s[3], s[4]) for i, s in enumerate(segs[:2])]
    line = time.strftime("%m-%d %H:%M") + "  " + label.ljust(28) + "  " + "  ".join("%s %.1f ms (%.1f fps; eng %.1f pic %.1f)" % r for r in results)
    with open(os.path.join(HERE, "bench", "results.txt"), "a") as f:
        f.write(line + "\n")
    print(line)


def summary(path):
    seg = "start"
    segs = []   # [name, rows]
    cur = [seg, []]
    num = r"(-?[\d.]+)"
    for line in open(path, errors="replace"):
        m = re.search(r"HP1 exec t=[\d.]+: (.*)", line)
        if m:
            if cur[1]:
                segs.append(cur)
            cur = [m.group(1)[:40], []]
            continue
        if "VitaBench:" not in line:
            continue
        def g(pat):
            mm = re.search(pat, line)
            return float(mm.group(1)) if mm else float("nan")
        cur[1].append(dict(
            fps=g(r"FPS " + num), minfps=g(r"min " + num), ms=g(r"FPS [\d.]+  min [\d.]+  " + num + " ms"),
            eng=g(r"engine " + num), pic=g(r"picture " + num), tick=g(r"tick " + num), bsp=g(r"bsp " + num),
            vis=g(r"vis " + num), draw=g(r"draw " + num), mesh=g(r"mesh " + num), surf=g(r"\| draw: sky/mirror [\d.]+  surf " + num),
            actors=g(r"actors " + num)))
    if cur[1]:
        segs.append(cur)
    if not segs:
        print("no VitaBench lines (VITA_BENCH=1 in the scenario?)")
        return
    print("%-40s %4s %6s %6s %6s %6s %6s %6s %6s %6s %6s" % ("segment", "n", "fps", "worst", "ms", "engine", "pict", "tick", "vis", "draw", "mesh"))
    for name, rows in segs:
        rows = rows[1:] if len(rows) > 2 else rows   # the first half second after a jump is warming up
        avg = lambda k: sum(r[k] for r in rows) / len(rows)
        print("%-40s %4d %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f" % (
            name, len(rows), avg("fps"), min(r["minfps"] for r in rows), avg("ms"), avg("eng"), avg("pic"), avg("tick"), avg("vis"), avg("draw"), avg("mesh")))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    what = sys.argv[1]
    if what == "find":
        find()
    elif what == "deploy":
        deploy()
    elif what == "run":
        run(sys.argv[2], "--deploy" in sys.argv)
    elif what == "bench":
        bench(sys.argv[2] if len(sys.argv) > 2 else "?", "--deploy" in sys.argv)
    elif what == "summary":
        summary(sys.argv[2])
    elif what == "cmd":
        print(cmd(sys.argv[2]))
    elif what == "clean":
        delete(f"{DATA}/env.txt")
        delete(f"{DATA}/args.txt")
        print("env.txt and args.txt removed")
    elif what == "get":
        get_file(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
