"""Run the dream CLI with this directory, never the cwd, first on sys.path.

`python3 -m` would put the cwd first, where a stray dreamlib/ replaces the
real package. Inserting the path explicitly does not depend on how the
interpreter builds sys.path (PYTHONSAFEPATH, -P, -I)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dreamlib.cli import main  # noqa: E402

raise SystemExit(main())
