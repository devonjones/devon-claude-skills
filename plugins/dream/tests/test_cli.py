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
