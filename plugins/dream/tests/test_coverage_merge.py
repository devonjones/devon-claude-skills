"""cli.py — the cumulative coverage record is the only copy of history.

The live log window is pruned, so recomputing from it destroys the count. Two
things must hold: the merge must keep the larger value, and an unreadable prior
must stop the write rather than be logged and then overwritten.

Fixtures use old > new, so a plain overwrite and a max-merge give different
answers - a fixture with new > old cannot tell them apart.
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
    """An unreadable prior must stop the write, not be logged and then
    overwritten with the pruned live window."""
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


def test_synth_keeps_one_file_per_source(review_out, monkeypatch):
    """Running synth for two sources must leave both scorecards. With a shared
    filename the second run overwrites the first, and the markers scorecard is
    the only one carrying operator taste."""
    monkeypatch.setattr(rv, "load_findings", lambda src: [{"reviewer": src}])
    monkeypatch.setattr(rv, "synth", lambda f: {"reviewer_count": 1, "who": f[0]["reviewer"]})
    monkeypatch.setattr(cli, "_render_scorecards", lambda s: s["who"])
    for src in ("markers", "all"):
        assert cli.cmd_reviews_synth(argparse.Namespace(source=src)) == 0
    assert json.loads((review_out / "scorecards-markers.json").read_text())["who"] == "markers"
    assert (review_out / "SCORECARDS-all.md").read_text() == "all"
