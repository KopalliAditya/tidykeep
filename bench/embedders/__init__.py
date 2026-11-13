"""Embedding methods for the duplicate-photo benchmark, by name.

Every method turns the images of a dataset into one vector (or bit string) each, in the
shared output format (see bench/README.md). Heavy imports happen inside each method, so
listing methods is cheap.
"""

from __future__ import annotations

from . import common  # noqa: F401  (sets HF_HOME / TORCH_HOME before anything imports torch)
from .apple import METHODS as _APPLE
from .common import Method
from .hashing import METHODS as _HASHING
from .neural import METHODS as _NEURAL

METHODS: dict[str, Method] = {m.name: m for m in (*_APPLE, *_HASHING, *_NEURAL)}

# Asked for but not runnable here, with the reason.
SKIPPED: dict[str, str] = {}
