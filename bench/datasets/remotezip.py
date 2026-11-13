"""Read members of a large remote zip over HTTP Range requests, without downloading all of it."""

from __future__ import annotations

import io
import time
import urllib.request


class HTTPRangeFile(io.RawIOBase):
    """A read-only, seekable file over an HTTP URL that honours Range requests."""

    def __init__(self, url: str, block: int = 1 << 20):
        self.url = url
        self.pos = 0
        self.block = block
        self._cache: dict[int, bytes] = {}
        req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            rng = r.headers.get("Content-Range")
            assert rng and "/" in rng, f"server does not support ranges: {r.headers}"
            self.size = int(rng.split("/")[-1])

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, offset: int, whence: int = 0) -> int:
        if whence == 0:
            self.pos = offset
        elif whence == 1:
            self.pos += offset
        else:
            self.pos = self.size + offset
        return self.pos

    def _fetch(self, start: int, end: int) -> bytes:
        for attempt in range(6):
            try:
                req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end - 1}"})
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = r.read()
                assert len(data) == end - start, (len(data), end - start)
                return data
            except Exception:
                if attempt == 5:
                    raise
                time.sleep(2 * (attempt + 1))
        raise RuntimeError("unreachable")

    def read(self, n: int = -1) -> bytes:
        if self.pos >= self.size:
            return b""
        if n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n > 4 * self.block:  # big reads go straight through
            data = self._fetch(self.pos, self.pos + n)
            self.pos += n
            return data
        out = bytearray()
        while n > 0:
            b = self.pos // self.block
            if b not in self._cache:
                if len(self._cache) > 64:
                    self._cache.clear()
                start = b * self.block
                self._cache[b] = self._fetch(start, min(self.size, start + self.block))
            chunk = self._cache[b][self.pos - b * self.block :][:n]
            out += chunk
            self.pos += len(chunk)
            n -= len(chunk)
        return bytes(out)

    def readinto(self, buf) -> int:
        data = self.read(len(buf))
        buf[: len(data)] = data
        return len(data)
