"""Run the dream CLI as a script, not with `python3 -m`.

A script puts its own directory first on sys.path; `-m` puts the cwd first,
where a stray dreamlib/ would replace the real package. This holds on every
Python 3, unlike PYTHONSAFEPATH (3.11+)."""
from dreamlib.cli import main

raise SystemExit(main())
