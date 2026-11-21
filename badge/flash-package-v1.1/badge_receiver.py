#!/usr/bin/env python3
"""MuseBadge Mac receiver — 边录边传接收端

Listens for the badge's UDP discovery broadcast, tells it where to
connect, then receives the live Ogg Opus stream over TCP and saves it
as a standard .ogg file (the badge's local copy stays the master).

Usage:  python3 badge_receiver.py
Files:  ~/Downloads/muse-badge-recordings/rec_<date>_<time>_<session>.ogg
If BadgePod （吧唧录音库） is installed, finished recordings are also copied
into its Inbox so it picks them up for transcription automatically.

Stdlib only. Ctrl+C to quit.
"""
import os
import socket
import struct
import sys
import threading
import time
from datetime import datetime

DISC_PORT = 47800
TCP_PORT = 47801
OUT_DIR = os.path.expanduser("~/Downloads/muse-badge-recordings")
BADGEPOD_INBOX = os.path.expanduser(
    "~/Library/Application Support/BadgePod/Inbox")

sessions = {}  # session_id -> dict(path, fh, pages, eos)


def ogg_crc(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 \
                else (crc << 1) & 0xFFFFFFFF
    return crc


class PageParser:
    """Incremental Ogg page parser: feed bytes, get complete pages."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data: bytes):
        self.buf += data
        pages = []
        while True:
            page = self._try_page()
            if page is None:
                break
            pages.append(page)
        return pages

    def _try_page(self):
        buf = self.buf
        idx = buf.find(b"OggS")
        if idx < 0:
            # keep a possible partial "OggS" tail
            del buf[: max(0, len(buf) - 3)]
            return None
        if idx > 0:
            del buf[:idx]  # drop garbage / partial page tail (resync)
        if len(buf) < 27:
            return None
        if buf[4] != 0:
            del buf[:4]
            return self._try_page()
        nseg = buf[26]
        if len(buf) < 27 + nseg:
            return None
        plen = sum(buf[27:27 + nseg])
        total = 27 + nseg + plen
        if len(buf) < total:
            return None
        page = bytes(buf[:total])
        del buf[:total]
        return page


def page_info(page: bytes):
    flags = page[5]
    granule = struct.unpack("<q", page[6:14])[0]
    seq = struct.unpack("<I", page[18:22])[0]
    return flags, granule, seq


def finalize(sess: dict):
    if sess["fh"]:
        sess["fh"].close()
        sess["fh"] = None
    path = sess["path"]
    size = os.path.getsize(path) if os.path.exists(path) else 0
    print(f"[完成] {path}  ({size/1024:.0f} KB, {sess['pages']} 页)")
    if os.path.isdir(BADGEPOD_INBOX):
        import shutil
        dst = os.path.join(BADGEPOD_INBOX, os.path.basename(path))
        try:
            shutil.copy2(path, dst)
            print(f"[吧唧录音库] 已投递到吧唧录音库收件箱：{dst}")
        except OSError as e:
            print(f"[吧唧录音库] 投递失败：{e}")


def handle_conn(conn: socket.socket, addr):
    f = conn.makefile("rb")
    line = f.readline(64).decode("ascii", "replace").strip()
    parts = line.split()
    if len(parts) != 3 or parts[0] != "MBR1":
        print(f"[连接] 来自 {addr} 的未知握手：{line!r}，忽略")
        conn.close()
        return
    session, cont = parts[1], parts[2] == "1"
    sess = sessions.get(session)
    if sess is None:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        path = os.path.join(OUT_DIR, f"rec_{stamp}_{session}.ogg")
        sess = {"path": path, "fh": None, "pages": 0, "eos": False}
        sessions[session] = sess
        print(f"[录音开始] 会话 {session} -> {path}")
    else:
        print(f"[重连] 会话 {session}（{'续传' if cont else '新流'}）")
    if sess["fh"] is None:
        sess["fh"] = open(sess["path"], "ab")
    parser = PageParser()
    try:
        while True:
            data = f.read(4096)
            if not data:
                break
            for page in parser.feed(data):
                flags, granule, seq = page_info(page)
                sess["fh"].write(page)
                sess["pages"] += 1
                if sess["pages"] % 50 == 0:
                    sess["fh"].flush()
                    dur = granule / 48000.0 if granule >= 0 else 0
                    print(f"[接收中] 会话 {session}：{dur:.0f} 秒 "
                          f"({os.path.getsize(sess['path'])/1024:.0f} KB)")
                if flags & 0x04:  # EOS
                    sess["eos"] = True
    except OSError as e:
        print(f"[连接中断] {e}")
    finally:
        conn.close()
    if sess["eos"]:
        finalize(sess)
        del sessions[session]
    else:
        if sess["fh"]:
            sess["fh"].flush()
        print(f"[暂停] 会话 {session} 连接断开，等吧唧重连续传"
              f"（本地主本在吧唧上，不受影响）")


def udp_responder():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    u.bind(("", DISC_PORT))
    while True:
        data, addr = u.recvfrom(256)
        if data.strip() == b"MUSEBADGE_DISC":
            u.sendto(f"MUSEREC {TCP_PORT}".encode(), addr)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    threading.Thread(target=udp_responder, daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("", TCP_PORT))
    srv.listen(4)
    try:
        host = socket.gethostbyname(socket.gethostname())
    except socket.gaierror:
        host = "?"
    print("MuseBadge 接收端已启动")
    print(f"  本机局域网地址：{host}（吧唧和 Mac 要在同一个 Wi-Fi 下）")
    print(f"  录音保存到：{OUT_DIR}")
    print(f"  吧唧录音库收件箱：{'已找到，录完自动投递' if os.path.isdir(BADGEPOD_INBOX) else '未安装吧唧录音库，跳过投递'}")
    print("  等待吧唧连接…（Ctrl+C 退出）")
    try:
        while True:
            conn, addr = srv.accept()
            handle_conn(conn, addr)
    except KeyboardInterrupt:
        print("\n退出。")
        for sess in list(sessions.values()):
            if sess["fh"]:
                sess["fh"].close()
        sys.exit(0)


if __name__ == "__main__":
    main()
