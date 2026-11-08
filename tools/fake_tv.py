"""Fake TV receiver for testing senders without a TV.

Speaks the TVMirror protocol, acks video frames, saves the video (Annex B H.264) and audio,
and prints stats. Usage: python fake_tv.py <out-prefix> <seconds> [port]
"""
import json, socket, struct, sys, time

out, seconds = sys.argv[1], float(sys.argv[2])
port = int(sys.argv[3]) if len(sys.argv) > 3 else 47800
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
srv.settimeout(120)
c, _ = srv.accept()
c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

def readn(n):
    b = b""
    while len(b) < n:
        x = c.recv(n - len(b))
        if not x:
            raise EOFError
        b += x
    return b

vid, aud = open(out + ".h264", "wb"), open(out + ".pcm", "wb")
t0 = time.time(); frames = keys = configs = abytes = vbytes = 0; first = None
try:
    while time.time() - t0 < seconds:
        h = readn(14)
        typ, flags = h[0], h[1]
        pts, ln = struct.unpack(">QI", h[2:])
        p = readn(ln)
        if typ == 0:
            print("HELLO", json.loads(p), flush=True)
        elif typ == 1:
            configs += 1
        elif typ == 2:
            frames += 1; keys += flags & 1; vbytes += ln; vid.write(p)
            if first is None:
                first = time.time() - t0
            c.sendall(struct.pack(">BBQI", 13, 0, pts, 0))
        elif typ == 3:
            abytes += ln; aud.write(p)
        elif typ == 4:
            print("BYE"); break
except EOFError:
    print("EOF")
dt = time.time() - t0
print(f"first frame after {first}s; {frames} frames ({frames / dt:.1f} fps), {keys} keyframes, {configs} configs, "
      f"{vbytes * 8 / dt / 1e6:.1f} Mbps video, {abytes / dt / 1000:.0f} kB/s audio", flush=True)
try:
    c.sendall(struct.pack(">BBQI", 4, 0, 0, 0)); c.close()
except OSError:
    pass
sys.exit(0 if frames > 0 else 1)
