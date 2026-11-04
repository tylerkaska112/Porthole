import zlib,struct
def vint(n):
    out=bytearray()
    while True:
        b=n&0x7f; n>>=7
        if n: out.append(b|0x80)
        else: out.append(b); break
    return bytes(out)
files=[("Game/",None),("Game/game.exe",b"MZ"+b"\x90"*300+b"PE"),("Game/data/",None),("Game/data/a.txt",b"hello rar\n"*50),("Game/empty.bin",b"")]
# ---- RAR5, stored
def block(btype,hflags,body,extra=b"",data_size=None):
    h=vint(btype)+vint(hflags)
    if data_size is not None: h+=vint(data_size)
    h+=body
    hs=vint(len(h))
    crc=struct.pack("<I",zlib.crc32(hs+h)&0xffffffff)
    return crc+hs+h
out=b"Rar!\x1a\x07\x01\x00"
out+=block(1,0,vint(0))
for name,data in files:
    isdir=data is None
    nm=name.rstrip("/").encode()
    body=vint(0x01 if isdir else 0x04)+vint(0 if isdir else len(data))+vint(0x10 if isdir else 0x20)
    if not isdir: body+=struct.pack("<I",zlib.crc32(data)&0xffffffff)
    body+=vint(0)+vint(0)+vint(len(nm))+nm
    out+=block(2,0x02,body,data_size=(0 if isdir else len(data)))+(b'' if isdir else data)
out+=block(5,0,vint(0))
open("stored5.rar","wb").write(out)
# ---- RAR4, stored
def hdr4(htype,flags,payload):
    size=7+len(payload)
    body=struct.pack("<BHH",htype,flags,size)+payload
    return struct.pack("<H",zlib.crc32(body)&0xffff)+body
out=b"Rar!\x1a\x07\x00"
out+=hdr4(0x73,0,b"\0\0\0\0\0\0")
for name,data in files:
    isdir=data is None
    nm=name.rstrip("/").encode()
    d=b"" if isdir else data
    flags=0x8000|(0xE0 if isdir else 0)
    payload=struct.pack("<IIBIIBBHI",len(d),len(d),2,zlib.crc32(d)&0xffffffff,0x5A0C0000,29 if True else 20,0x30,len(nm),0x10 if isdir else 0x20)+nm
    out+=hdr4(0x74,flags,payload)+d
out+=hdr4(0x7B,0x4000,b"")
open("stored4.rar","wb").write(out)
print("ok")
