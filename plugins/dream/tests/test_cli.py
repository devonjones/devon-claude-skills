"""cli.py — digest cache freshness (the model-retry contract)."""

import json

from dreamlib import cli


def _digest(tmp_path, **extra):
    d = {"input_hash": "h1", **extra}
    p = tmp_path / "d.json"
    p.write_text(json.dumps(d), encoding="utf-8")
    return str(p)


def test_cache_fresh_missing_file(tmp_path):
    assert cli._cache_fresh(str(tmp_path / "nope.json"), "h1", want_model=True) is False


def test_cache_fresh_input_hash_change_is_stale(tmp_path):
    p = _digest(tmp_path, model={"insights": []})
    assert cli._cache_fresh(p, "h2", want_model=True) is False


def test_cache_fresh_successful_model_is_fresh(tmp_path):
    p = _digest(tmp_path, model={"insights": []})
    assert cli._cache_fresh(p, "h1", want_model=True) is True


def test_cache_fresh_heuristic_only_is_stale_for_model_run(tmp_path):
    p = _digest(tmp_path)  # no model key
    assert cli._cache_fresh(p, "h1", want_model=True) is False
    # ...but fresh when no model was requested.
    assert cli._cache_fresh(p, "h1", want_model=False) is True


def test_cache_fresh_model_error_is_retried_not_poisoned(tmp_path):
    # A transient failure (host offline) must NOT count as satisfying want_model,
    # else a blip permanently poisons the digest and no later run re-enriches it.
    p = _digest(tmp_path, model_error="<urlopen error [Errno 113] No route to host>")
    assert cli._cache_fresh(p, "h1", want_model=True) is False
    # Without a model request it's still fine to reuse.
    assert cli._cache_fresh(p, "h1", want_model=False) is True


# --- coverage merge-forward ------------------------------------------------
# The session-log window is pruned, so recomputing coverage each run destroys
# history (wyrd went 1,360 spawns -> 0 with no reviewer actually going quiet).


def test_merge_coverage_keeps_high_water_mark():
    old = {"total_spawns": 104, "reviewers": [
        {"reviewer": "a-reviewer", "spawns": 100, "prs": 9,
         "first_seen": "2026-06-01", "last_seen": "2026-07-08"},
        {"reviewer": "b-reviewer", "spawns": 4, "prs": 1,
         "first_seen": "2026-06-02", "last_seen": "2026-06-30"},
    ]}
    new = {"total_spawns": 0, "reviewers": []}  # window fully pruned
    m = cli._merge_coverage(old, new)
    assert m["total_spawns"] == 104
    assert m["live_window_spawns"] == 0
    assert {r["reviewer"] for r in m["reviewers"]} == {"a-reviewer", "b-reviewer"}


def test_merge_coverage_extends_span_and_adds_new_reviewers():
    old = {"total_spawns": 5, "reviewers": [
        {"reviewer": "a-reviewer", "spawns": 5, "prs": 2,
         "first_seen": "2026-06-01", "last_seen": "2026-06-10"},
    ]}
    new = {"total_spawns": 9, "reviewers": [
        {"reviewer": "a-reviewer", "spawns": 7, "prs": 3,
         "first_seen": "2026-06-05", "last_seen": "2026-07-01"},
        {"reviewer": "c-reviewer", "spawns": 2, "prs": 1,
         "first_seen": "2026-07-01", "last_seen": "2026-07-01"},
    ]}
    m = cli._merge_coverage(old, new)
    a = next(r for r in m["reviewers"] if r["reviewer"] == "a-reviewer")
    assert a["spawns"] == 7 and a["prs"] == 3       # max, not overwrite
    assert a["first_seen"] == "2026-06-01"          # earliest ever seen
    assert a["last_seen"] == "2026-07-01"           # latest ever seen
    assert m["total_spawns"] == 9                   # 7 + 2
