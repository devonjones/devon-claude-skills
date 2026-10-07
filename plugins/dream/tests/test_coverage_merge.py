"""cli.py — the cumulative coverage record is the only copy of history.

The live log window is pruned, so recomputing from it destroys the count. Two
things must hold: the merge must keep the larger value, and an unreadable prior
must stop the write rather than be logged and then overwritten.

The pre-existing merge tests passed against a plain overwrite, because their
fixture had new > old in every field and the high-water case passed an empty
reviewer list so the loop body never ran. Every fixture here is discriminating:
old > new, so max and overwrite give different answers.
"""

import argparse
import json

import pytest

from dreamlib import cli
from dreamlib import reviews as rv


def _cov(spawns, prs, reviewer="clarity-reviewer", **extra):
    return {"reviewers": [{"reviewer": reviewer, "spawns": spawns, "prs": prs,
                           "first_seen": extra.get("first", "2026-01-01"),
                           "last_seen": extra.get("last", "2026-01-02")}],
            "total_spawns": spawns}


def test_merge_keeps_the_larger_count_old_greater_than_new():
    """Discriminating: old 100/9 vs new 7/2. Overwrite gives 7/2, max gives 100/9."""
    out = cli._merge_coverage(_cov(100, 9), _cov(7, 2))
    assert out["reviewers"][0]["spawns"] == 100
    assert out["reviewers"][0]["prs"] == 9
    assert out["total_spawns"] == 100


def test_merge_records_the_live_window_separately():
    out = cli._merge_coverage(_cov(100, 9), _cov(7, 2))
    assert out["live_window_spawns"] == 7


def test_merge_widens_the_seen_window():
    out = cli._merge_coverage(
        _cov(5, 1, first="2026-01-01", last="2026-01-05"),
        _cov(5, 1, first="2026-02-01", last="2026-02-05"))
    r = out["reviewers"][0]
    assert r["first_seen"] == "2026-01-01"
    assert r["last_seen"] == "2026-02-05"


def test_merge_keeps_a_reviewer_absent_from_the_live_window():
    """A reviewer that did not fire this window must not vanish — that is the
    reader-retires-a-productive-reviewer failure the merge exists to prevent."""
    out = cli._merge_coverage(_cov(42, 3, reviewer="silent-failure-hunter"),
                              _cov(1, 1, reviewer="clarity-reviewer"))
    names = {r["reviewer"] for r in out["reviewers"]}
    assert "silent-failure-hunter" in names


@pytest.fixture
def review_out(tmp_path, monkeypatch):
    monkeypatch.setattr(rv, "REVIEW_OUT", str(tmp_path))
    return tmp_path


def test_unreadable_prior_refuses_to_write_and_leaves_the_file(review_out, monkeypatch):
    """The whole P1: it used to log 'unreadable — not merged' and then write the
    pruned live window over the only cumulative record."""
    path = review_out / "coverage.json"
    path.write_text("{truncated", encoding="utf-8")
    monkeypatch.setattr(rv, "coverage_from_logs", lambda: _cov(1, 1))
    rc = cli.cmd_reviews_coverage(argparse.Namespace(no_merge=False))
    assert rc != 0
    assert path.read_text(encoding="utf-8") == "{truncated"


def test_readable_prior_is_merged_and_written(review_out, monkeypatch):
    path = review_out / "coverage.json"
    path.write_text(json.dumps(_cov(100, 9)), encoding="utf-8")
    monkeypatch.setattr(rv, "coverage_from_logs", lambda: _cov(7, 2))
    assert cli.cmd_reviews_coverage(argparse.Namespace(no_merge=False)) == 0
    assert json.loads(path.read_text(encoding="utf-8"))["total_spawns"] == 100


def test_heading_says_which_mode_it_ran_in(review_out, monkeypatch):
    """The heading claimed "cumulative ... merged forward" unconditionally, which
    is false under --no-merge, and that heading is what a reader uses to decide
    whether a zero means a quiet reviewer or a pruned window."""
    monkeypatch.setattr(rv, "coverage_from_logs", lambda: _cov(3, 1))
    assert cli.cmd_reviews_coverage(argparse.Namespace(no_merge=True)) == 0
    assert "LIVE WINDOW ONLY" in (review_out / "COVERAGE.md").read_text(encoding="utf-8")

    (review_out / "coverage.json").write_text(json.dumps(_cov(100, 9)), encoding="utf-8")
    assert cli.cmd_reviews_coverage(argparse.Namespace(no_merge=False)) == 0
    assert "merged forward" in (review_out / "COVERAGE.md").read_text(encoding="utf-8")
