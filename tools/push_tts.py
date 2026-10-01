#!/usr/bin/env python3
"""Push Global.lua + UI to a running Tabletop Simulator ("Save & Play") without VS Code.

Uses TTS's External Editor API (TCP on localhost: send to 39999, TTS replies on 39998).
Flattens `#include name` lines in src/Global.lua exactly like tools/build.lua.
Stdlib only. Run from anywhere:   python3 tools/push_tts.py [--host 127.0.0.1] [--logs]

--logs  stay connected afterwards and print TTS chat/log/error messages (Ctrl+C to quit).
Load a game in TTS first. Save & Play reloads the table with the new scripts.
"""
import argparse, json, os, re, socket, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEND_PORT, RECV_PORT = 39999, 39998
MSG_SAVE_AND_PLAY = 1
IN_PRINT, IN_ERROR = 2, 3


def read(rel):
    with open(os.path.join(ROOT, rel), "r", encoding="utf-8", newline="") as f:
        return f.read()


def flatten(name, seen):
    if name in seen:
        return ""
    seen.add(name)
    out = []
    for line in read("src/%s.lua" % name).replace("\r\n", "\n").split("\n"):
        m = re.match(r"#include\s+(\S+)", line)
        out.append(flatten(m.group(1), seen) if m else line)
    return "\n".join(out)


def listen(host):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, RECV_PORT))
    srv.listen(5)
    return srv


def show(msg):
    t = msg.get("messageID")
    if t == IN_PRINT:
        print(msg.get("message", ""))
    elif t == IN_ERROR:
        print("ERROR:", msg.get("error", ""), msg.get("errorMessagePrefix", ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--logs", action="store_true")
    args = ap.parse_args()

    script = flatten("Global", set())
    payload = {"messageID": MSG_SAVE_AND_PLAY,
               "scriptStates": [{"guid": "-1", "script": script, "ui": read("ui/Global.xml")}]}

    srv = listen(args.host) if args.logs else None
    try:
        with socket.create_connection((args.host, SEND_PORT), timeout=5) as s:
            s.sendall(json.dumps(payload).encode("utf-8"))
    except OSError as e:
        sys.exit("Cannot reach TTS on %s:%d (%s). Is TTS running with a game loaded?" % (args.host, SEND_PORT, e))
    print("pushed Global.lua (%d bytes) to TTS" % len(script))

    if srv:
        print("listening for TTS output... (Ctrl+C to quit)")
        try:
            while True:
                conn, _ = srv.accept()
                with conn:
                    data = b""
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                try:
                    show(json.loads(data.decode("utf-8")))
                except ValueError:
                    pass
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
