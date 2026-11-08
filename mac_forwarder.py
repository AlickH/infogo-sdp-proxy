#!/usr/bin/env python3
"""本地 TCP 转发：127.0.0.1:11085 -> 10.0.0.2:11085 (经 WireGuard 隧道)
用途：Surge 会绕过 VPN 直接连代理服务器 IP，所以让 Surge 连本机回环地址。
目标：NAS 上的 Linux 小助手隧道（netns 内 SOCKS5）"""
import socket, threading, time

LISTEN = ("127.0.0.1", 11085)
TARGET = ("10.0.0.2", 11085)
BUF = 65536

def pipe(src, dst):
    try:
        while True:
            data = src.recv(BUF)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass

def handle(client):
    try:
        upstream = socket.create_connection(TARGET, timeout=10)
        upstream.settimeout(None)
        client.settimeout(None)
    except OSError as e:
        print(f"connect upstream failed: {e}", flush=True)
        try: client.close()
        except OSError: pass
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(64)
    print(f"listening on {LISTEN} -> {TARGET}", flush=True)
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            time.sleep(0.2); continue
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
