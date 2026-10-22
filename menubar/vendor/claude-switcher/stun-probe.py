#!/usr/bin/env python3
"""WebRTC 泄漏探测:并发向多个 STUN 服务器(含国内节点)发 UDP Binding 请求。
走隧道时应得到代理出口 IP,裸连时会暴露真实国内 IP。全程硬超时 10 秒,绝不阻塞。"""
import socket, struct, os, signal, threading

SERVERS = [
    ("stun.miwifi.com", 3478),        # 国内节点:裸连时必有响应
    ("stun.chat.bilibili.com", 3478), # 国内节点
    ("stun.l.google.com", 19302),     # 全球节点
    ("stun.cloudflare.com", 3478),    # 全球节点
]

def stun_public_ip(host, port, timeout=2.0):
    try:
        addr = socket.gethostbyname(host)
    except Exception:
        return None
    txn = os.urandom(12)
    req = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + txn
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(req, (addr, port))
        data, _ = s.recvfrom(1024)
    except Exception:
        return None
    finally:
        s.close()
    if len(data) < 20 or data[0:2] != b"\x01\x01":
        return None
    pos = 20
    while pos + 4 <= len(data):
        atype, alen = struct.unpack("!HH", data[pos:pos+4])
        aval = data[pos+4:pos+4+alen]
        if atype == 0x0020 and len(aval) >= 8 and aval[1] == 0x01:
            ip_int = struct.unpack("!I", aval[4:8])[0] ^ 0x2112A442
            return socket.inet_ntoa(struct.pack("!I", ip_int))
        if atype == 0x0001 and len(aval) >= 8 and aval[1] == 0x01:
            return socket.inet_ntoa(aval[4:8])
        pos += 4 + alen + ((4 - alen % 4) % 4)
    return None

def _alarm(signum, frame):
    raise TimeoutError

def main():
    found = []
    lock = threading.Lock()
    def worker(h, p):
        ip = stun_public_ip(h, p)
        if ip:
            with lock:
                if ip not in found:
                    found.append(ip)
    threads = []
    for h, p in SERVERS:
        t = threading.Thread(target=worker, args=(h, p), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=3)
    print("RESULT:" + (",".join(found) if found else "NONE"))

signal.signal(signal.SIGALRM, _alarm)
signal.alarm(10)
try:
    main()
except TimeoutError:
    print("RESULT:NONE")
