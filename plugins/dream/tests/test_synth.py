"""synth.py — route suggestion gates + lexical helpers."""

from dreamlib import synth


def test_suggest_route_uses_majority_target():
    members = [{"target": "doc"}, {"target": "doc"}, {"target": "memory"}]
    assert synth._suggest_route(members, frequency=3, known=None) == "doc"


def test_suggest_route_downgrades_single_session_claude_md():
    members = [{"target": "claude_md"}]
    assert synth._suggest_route(members, frequency=1, known=None) == "memory"


def test_suggest_route_keeps_recurring_claude_md():
    members = [{"target": "claude_md"}]
    assert synth._suggest_route(members, frequency=2, known=None) == "claude_md"


def test_suggest_route_strong_decisions_match_is_product_decision():
    members = [{"target": "doc"}]
    known = {"artifact": "wyrd/DECISIONS.md", "coverage": 0.6}
    assert synth._suggest_route(members, frequency=1, known=known) == "product_decision"


def test_suggest_route_weak_decisions_match_does_not_reroute():
    members = [{"target": "doc"}]
    known = {"artifact": "DECISIONS.md", "coverage": 0.3}  # below KNOWN_THRESHOLD
    assert synth._suggest_route(members, frequency=1, known=known) == "doc"


def test_jaccard_and_tokens():
    a = synth._tokens("the quick brown fox jumps")
    b = synth._tokens("the quick brown cat sleeps")
    assert synth._jaccard(a, a) == 1.0
    assert synth._jaccard(a, set()) == 0.0
    assert 0.0 < synth._jaccard(a, b) < 1.0


def test_tokens_drop_stopwords_and_short_words():
    toks = synth._tokens("the a an and quick")
    assert "quick" in toks
    assert "the" not in toks  # stopword
