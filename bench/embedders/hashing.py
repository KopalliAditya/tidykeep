"""Perceptual hashes: what czkawka, digiKam, dupeGuru-style tools and most dedup apps use.

imagehash defaults (hash_size 8, so 64 bits), and Meta's PDQ (256 bits) via the pdqhash
package, which wraps the reference C++ implementation. Compared by Hamming distance.
"""

from __future__ import annotations

import time

import numpy as np

from .common import Context, Method, Result, load_rgb, median_ms


def _imagehash(fn_name: str):
    def run(ctx: Context) -> Result:
        import imagehash

        fn = getattr(imagehash, fn_name)
        bits, times = [], []
        for p in ctx.paths:
            im = load_rgb(p)
            t = time.perf_counter()
            h = fn(im)
            times.append((time.perf_counter() - t) * 1000)
            bits.append(np.asarray(h.hash, dtype=np.uint8).reshape(-1))
        return Result(X=np.stack(bits), ms_per_image=median_ms(times), device="cpu", model_mb=0.0,
                      notes=f"imagehash {imagehash.__version__} {fn_name}() defaults; bits row-major from ImageHash.hash")

    return run


def _pdq_available() -> str | None:
    try:
        import pdqhash  # noqa: F401
    except Exception as e:  # pragma: no cover
        return f"pdqhash not importable: {e}"
    return None


def _pdq(ctx: Context) -> Result:
    import pdqhash

    bits, quality, times = [], [], []
    for p in ctx.paths:
        im = load_rgb(p)
        t = time.perf_counter()
        # As Meta's reference (pdq/python PDQHasher.fromFile): fit in 512x512 first, then hash.
        im.thumbnail((512, 512))
        h, q = pdqhash.compute(np.ascontiguousarray(np.asarray(im, dtype=np.uint8)))
        times.append((time.perf_counter() - t) * 1000)
        bits.append(np.asarray(h, dtype=np.uint8))
        quality.append(q)
    return Result(X=np.stack(bits), ms_per_image=median_ms(times), device="cpu", model_mb=0.0,
                  notes="image fitted in 512x512 (PIL thumbnail) as Meta's reference fromFile does, then "
                        "pdqhash.compute() (matches the reference bit for bit); bit order = reference hex string, "
                        "MSB first; PDQ quality (0-100) per image in npz array 'quality'",
                  extra_arrays={"quality": np.array(quality, dtype=np.int16)})


_IH = "BSD-2-Clause (imagehash)"
METHODS = [
    Method("ahash", "hamming", "Average hash, 8x8 grayscale vs. its mean, 64 bits (imagehash.average_hash)",
           _IH, "none (no learned weights)", _imagehash("average_hash")),
    Method("phash", "hamming", "Perceptual hash, DCT of 32x32 grayscale, 64 bits (imagehash.phash)",
           _IH, "none (no learned weights)", _imagehash("phash")),
    Method("dhash", "hamming", "Difference hash, horizontal gradient of 9x8 grayscale, 64 bits (imagehash.dhash)",
           _IH, "none (no learned weights)", _imagehash("dhash")),
    Method("whash", "hamming", "Wavelet hash, Haar, 64 bits (imagehash.whash defaults)",
           _IH, "none (no learned weights)", _imagehash("whash")),
    Method("pdq", "hamming", "Meta PDQ, 256-bit DCT hash with Jarosz filtering (pdqhash package, reference C++)",
           "BSD-3-Clause (PDQ reference, facebook/ThreatExchange); MIT (pdqhash Python bindings)", "none (no learned weights)",
           _pdq, _pdq_available),
]
