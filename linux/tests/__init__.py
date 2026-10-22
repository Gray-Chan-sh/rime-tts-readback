"""Unit tests for the Linux re-implementation (standard library only).

Run from the linux/ directory:

    python3 -m unittest discover -s tests -v

The text, config and patch tests also run on Windows/macOS because they never
touch a real Rime directory; every path is a temporary directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

LINUX_DIR = Path(__file__).resolve().parent.parent
if str(LINUX_DIR) not in sys.path:
    sys.path.insert(0, str(LINUX_DIR))
