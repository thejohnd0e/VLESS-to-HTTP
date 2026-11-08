"""SOCKS5 UDP check for tests/e2e.sh: UDP ASSOCIATE, then one DNS query (example.com A) to 1.1.1.1:53
through the relay address the proxy announced. Exit 0 when a matching DNS answer comes back.
usage: socks5_udp.py PROXY_HOST PROXY_PORT [USER PASS]"""
import socket
import struct
import sys

host, port = sys.argv[1], int(sys.argv[2])
user = sys.argv[3].encode() if len(sys.argv) > 4 else None
password = sys.argv[4].encode() if len(sys.argv) > 4 else None

tcp = socket.create_connection((host, port), 5)
tcp.sendall(b"\x05\x01" + (b"\x02" if user else b"\x00"))
ver, method = tcp.recv(2)
if user:
    assert method == 2, f"proxy did not ask for a login (method {method})"
    tcp.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
    assert tcp.recv(2)[1] == 0, "login refused"
else:
    assert method == 0, f"proxy wants authentication (method {method})"

tcp.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
r = tcp.recv(262)
assert r[1] == 0, f"UDP ASSOCIATE refused (rep={r[1]})"
if r[3] == 1:
    relay = (socket.inet_ntoa(r[4:8]), struct.unpack(">H", r[8:10])[0])
elif r[3] == 4:
    relay = (socket.inet_ntop(socket.AF_INET6, r[4:20]), struct.unpack(">H", r[20:22])[0])
else:
    n = r[4]
    relay = (r[5:5 + n].decode(), struct.unpack(">H", r[5 + n:7 + n])[0])
print(f"relay announced: {relay[0]}:{relay[1]}")

query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
packet = b"\x00\x00\x00\x01" + socket.inet_aton("1.1.1.1") + struct.pack(">H", 53) + query
udp = socket.socket(socket.AF_INET6 if ":" in relay[0] else socket.AF_INET, socket.SOCK_DGRAM)
udp.settimeout(6)
for attempt in range(3):
    udp.sendto(packet, relay)
    try:
        data, _ = udp.recvfrom(4096)
    except socket.timeout:
        continue
    # reply = SOCKS5 UDP header (10 bytes for IPv4) + DNS message with our ID
    if data[10:12] == b"\x12\x34":
        print("DNS answer received through the tunnel")
        sys.exit(0)
print("no DNS answer through the relay")
sys.exit(1)
