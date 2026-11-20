#!/usr/bin/env python3
"""RM520N attach helper for the bench (run after `make up` has printed NG Setup and the [rt] lines).

    modem_attach.py up   <usb-serial> [--timeout 600] [--server 10.45.0.1] [--no-data-path]
    modem_attach.py down <usb-serial>

`up`: AT+CFUN=1, wait for +C5GREG registered, AT+QIACT=1, AT+CGPADDR=1, AT+QPING x4; then the host data path:
find the modem's QMI device and net interface by its USB serial (same USB device as the AT port), start the
QMI data session (qmicli via qmi-proxy, retried), raw-IP, UE address /32 and a /32 route to the server.
Prints `IF=<iface> UE=<ip>` on success. `down`: host path down, AT+CFUN=4.
Only AT commands on ALLOWED are ever sent; nothing writes the SIM or modem firmware. Root steps use `sudo -n`.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import time

ALLOWED = [r"AT", r"AT\+CFUN=[014]", r"AT\+CFUN\?", r"AT\+CIMI", r'AT\+QENG="servingcell"', r"AT\+C5GREG\?",
           r"AT\+CGPADDR=1", r"AT\+QIACT=1", r"AT\+QIACT\?", r"AT\+QRSRP", r'AT\+QPING=1,"[0-9.]+",\d+,\d+']
SYSFS = "/sys"


def allowed(cmd):
    return any(re.fullmatch(p, cmd) for p in ALLOWED)


def at_port(serial):
    if not re.fullmatch(r"[0-9a-fA-F]{6,16}", serial):
        sys.exit(f"modem_attach: bad USB serial {serial!r}")
    return f"/dev/serial/by-id/usb-Quectel_RM520N-GL_{serial}-if02-port0"


def at(port, cmd, wait=8.0, done=None):
    """Send one allowed command; return the reply when OK/ERROR (or `done`) is seen, or at timeout."""
    if not allowed(cmd):
        raise ValueError(f"AT command not on the allowlist: {cmd}")
    import serial  # pyserial; imported here so the pure helpers test without it
    with serial.Serial(port, 115200, timeout=0.1) as s:
        s.reset_input_buffer()
        s.write(cmd.encode() + b"\r")
        end, buf = time.monotonic() + wait, b""
        while time.monotonic() < end:
            buf += s.read(4096)
            t = buf.decode("utf-8", "replace")
            if "ERROR" in t or (re.search(done, t) if done else "\nOK" in t):
                break
    return " ".join(buf.decode("utf-8", "replace").split())


def registered(reply):
    return re.search(r"\+C5GREG: \d,[15]\b", reply) is not None


def usb_device(path):
    """USB device name ('1-4') of a sysfs interface path ('.../1-4/1-4:1.2')."""
    return os.path.basename(os.path.realpath(path)).split(":")[0]


def qmi_for(at_dev, sysfs=SYSFS):
    """(/dev/cdc-wdmN, net iface) on the same USB device as the AT tty, or None."""
    tty = os.path.basename(os.path.realpath(at_dev))
    usb = usb_device(os.path.join(sysfs, "class/tty", tty, "device"))
    for d in sorted(glob.glob(os.path.join(sysfs, "class/usbmisc/cdc-wdm*"))):
        if usb_device(os.path.join(d, "device")) == usb:
            nets = sorted(os.listdir(os.path.join(d, "device/net")))
            if nets:
                return "/dev/" + os.path.basename(d), nets[0]
    return None


def sh(*a, check=True):
    r = subprocess.run(a, capture_output=True, text=True, timeout=60)
    if check and r.returncode:
        raise RuntimeError(f"{' '.join(a)}: rc={r.returncode} {r.stderr.strip()[:200]}")
    return r.stdout


def data_path_up(wdm, iface, server):
    for i in range(3):  # the first call after qmi-proxy starts can time out on the CTL service
        r = subprocess.run(["sudo", "-n", "qmicli", "-d", wdm, "--device-open-proxy",
                            "--wds-start-network=apn=internet,ip-type=4", "--client-no-release-cid"],
                           capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            break
        time.sleep(5)
    out = sh("sudo", "-n", "qmicli", "-d", wdm, "--device-open-proxy", "--wds-get-current-settings")
    m = re.search(r"IPv4 address:\s*([0-9.]+)", out)
    if not m:
        raise RuntimeError("no IPv4 address from the QMI session")
    ue = m.group(1)
    sh("sudo", "-n", "ip", "link", "set", iface, "down")
    subprocess.run(["sudo", "-n", "tee", f"/sys/class/net/{iface}/qmi/raw_ip"], input="Y", capture_output=True, text=True, check=True)
    sh("sudo", "-n", "ip", "addr", "flush", "dev", iface)
    sh("sudo", "-n", "ip", "addr", "add", f"{ue}/32", "dev", iface)
    sh("sudo", "-n", "ip", "link", "set", iface, "up")
    sh("sudo", "-n", "ip", "route", "replace", f"{server}/32", "dev", iface, "src", ue)
    return ue


def up(a):
    port = at_port(a.serial)
    log = lambda *m: print(time.strftime("%H:%M:%S"), *m, flush=True)
    log(at(port, "AT+CFUN=1", 20))
    t0 = time.monotonic()
    while not registered(g := at(port, "AT+C5GREG?")):
        if time.monotonic() - t0 > a.timeout:
            sys.exit(f"modem_attach: not registered within {a.timeout} s ({g})")
        time.sleep(15)
    log(f"registered after {time.monotonic() - t0:.0f} s")
    log(at(port, "AT+QIACT=1", 30))
    log(at(port, "AT+CGPADDR=1"))
    p = at(port, f'AT+QPING=1,"{a.server}",4,4', 30, done=r"\+QPING: \d+,\d+,\d+,\d+")
    log(p)
    if not re.search(r"\+QPING: 0,4,4,0", p):
        sys.exit("modem_attach: modem pings to the server failed")
    if a.no_data_path:
        return
    q = qmi_for(port)
    if not q:
        sys.exit("modem_attach: no QMI device on the modem's USB device")
    ue = data_path_up(*q, a.server)
    print(f"IF={q[1]} UE={ue} WDM={q[0]}")


def down(a):
    port = at_port(a.serial)
    q = qmi_for(port)
    if q:
        for c in (["ip", "addr", "flush", "dev", q[1]], ["ip", "link", "set", q[1], "down"]):
            subprocess.run(["sudo", "-n", *c], capture_output=True)
    print(at(port, "AT+CFUN=4", 20))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=("up", "down"))
    ap.add_argument("serial", help="modem USB serial, e.g. the <id> in /dev/serial/by-id/usb-Quectel_RM520N-GL_<id>-if02-port0")
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--server", default="10.45.0.1")
    ap.add_argument("--no-data-path", action="store_true")
    a = ap.parse_args(argv)
    (up if a.action == "up" else down)(a)


if __name__ == "__main__":
    main()
