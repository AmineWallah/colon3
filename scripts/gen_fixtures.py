import sys, struct, zlib
sys.path.insert(0, sys.argv[1])
from pynicotine import slskmessages as m

def u32(v): return struct.pack("<I", v)
def u64(v): return struct.pack("<Q", v)
def s(t): b = t.encode(); return u32(len(b)) + b
def server_frame(code, payload): return u32(len(payload) + 4) + u32(code) + payload
def peer_frame(code, payload): return u32(len(payload) + 4) + u32(code) + payload
def init_frame(code, payload): return u32(len(payload) + 1) + bytes([code]) + payload
def ip(a): return bytes(reversed(bytes(int(x) for x in a.split("."))))

fx = {}
fx["loginRequest"] = server_frame(1, m.Login("username", "password", 177, 1).make_network_message())
fx["fileSearchRequest"] = server_frame(26, m.FileSearch(token=1234, text="aphex twin xtal").make_network_message())
fx["loginSuccess"] = server_frame(1, b"\x01" + s("Welcome to Soulseek") + ip("203.0.113.7") + s("5f4dcc3b5aa765d61d8327deb882cf99") + b"\x00")
fx["loginFailure"] = server_frame(1, b"\x00" + s("INVALIDPASS"))
fx["connectToPeer"] = server_frame(18, s("peer_user") + s("P") + ip("198.51.100.23") + u32(2234) + u32(987654) + b"\x00" + u32(0) + u32(0))
fx["getPeerAddress"] = server_frame(3, s("peer_user") + ip("198.51.100.23") + u32(2234) + u32(0) + struct.pack("<H", 0))
fx["peerInit"] = init_frame(1, m.PeerInit(init_user="me", conn_type="P").make_network_message())
fx["pierceFirewall"] = init_frame(0, m.PierceFireWall(token=987654).make_network_message())
shares = [
    ("Music\\Aphex Twin\\Selected Ambient Works 85-92\\01 - Xtal.flac", 31457280, (None, None, 44100, 16), 294),
    ("Music\\Aphex Twin\\Selected Ambient Works 85-92\\02 - Tha.mp3", 21000000, (320, 0, None, None), 545),
    ("Music\\Ünïcødé\\track é.mp3", 1000, None, None),
]
fx["fileSearchResponse"] = peer_frame(9, m.FileSearchResponse("peer_user", 1234, shares, True, 5000, 3).make_network_message())
fx["transferRequestUpload"] = peer_frame(40, m.TransferRequest(1, 4242, shares[0][0], 31457280).make_network_message())
fx["transferResponseAllowed"] = peer_frame(41, m.TransferResponse(allowed=True, token=4242).make_network_message())
fx["transferResponseRejected"] = peer_frame(41, m.TransferResponse(allowed=False, reason="Queued", token=4242).make_network_message())
fx["queueUpload"] = peer_frame(43, m.QueueUpload(file=shares[1][0]).make_network_message())
fx["uploadDenied"] = peer_frame(50, s(shares[1][0]) + s("File not shared."))
fx["placeInQueueResponse"] = peer_frame(44, m.PlaceInQueueResponse(shares[1][0], 7).make_network_message())

# Uncompressed SharedFileListResponse payload for one public folder, built per the protocol doc
def fileinfo(name, size, attrs):
    out = b"\x01" + s(name) + u64(size) + s("") + u32(len(attrs))
    for k, v in attrs: out += u32(k) + u32(v)
    return out
shared = u32(1) + s("colon3\\Album") + u32(1) + fileinfo("song.mp3", 5000, []) + u32(0) + u32(0)
fx["sharedFileListPayloadUncompressed"] = shared

print("// Generated from Nicotine+ pynicotine/slskmessages.py encoders (and hand-built server replies).")
print("// Regenerate with scripts/gen_fixtures.py; do not edit by hand.")
print("enum Fixtures {")
for k, v in fx.items():
    print(f'    static let {k} = "{v.hex()}"')
print("}")
