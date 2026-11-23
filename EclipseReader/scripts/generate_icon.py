"""Original code-drawn app icon. Standard library only; no external artwork."""
from pathlib import Path
import math
import struct
import zlib

def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)

def generate(destination):
    size = 1024
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            value = 12 + int(9 * (1 - y / size))
            color = (value, value + 1, value + 4)
            # Eclipse and a spare, open-book silhouette.
            circle = math.hypot(x - 512, y - 365)
            cutout = math.hypot(x - 578, y - 318)
            if circle < 178 and cutout > 154:
                color = (226, 229, 237)
            if 264 <= x <= 760 and 608 <= y <= 780:
                distance = abs(x - 512)
                top = 613 + distance * 0.20
                bottom = 738 + distance * 0.20
                if top <= y <= bottom and (distance < 6 or y <= top + 9 or y >= bottom - 9 or distance >= 239):
                    color = (226, 229, 237)
            rows.extend(color)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b'')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(png)
    print(destination)

if __name__ == '__main__':
    generate(Path(__file__).resolve().parents[1] / 'Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png')
