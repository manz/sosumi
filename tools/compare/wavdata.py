"""Copies the data chunk of a WAV file to a raw file."""
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
b = open(src, "rb").read()
i = 12
while i + 8 <= len(b):
    tag, n = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
    if tag == b"data":
        open(dst, "wb").write(b[i + 8:i + 8 + n])
        break
    i += 8 + n + (n & 1)
else:
    sys.exit("no data chunk in " + src)
