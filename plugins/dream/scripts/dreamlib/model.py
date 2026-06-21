"""Stage 1b: enrich a heuristic digest via a local ollama model.

Runs against a local ollama (default http://localhost:11434; override with
WYRD_OLLAMA_URL / DREAM_MODEL). Uses ollama's
`format: json` to force valid JSON output, so no fragile parsing. The model
turns the bounded transcript into structured fields + candidate insights — but
it only *proposes*; promotion/dedup happens later in stage 2/3.
"""

from __future__ import annotations

import json
import os
import urllib.request

DEFAULT_URL = os.environ.get("WYRD_OLLAMA_URL", "http://localhost:11434")
DEFAULT_MODEL = os.environ.get("DREAM_MODEL", "qwen2.5:7b")

# JSON Schema we ask ollama to fill (also passed as `format` for grammar-level
# enforcement on models/servers that support it; the prompt restates it).
DIGEST_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string"},
        "constraints": {"type": "array", "items": {"type": "string"}},
        "discoveries": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "friction_summary": {"type": "array", "items": {"type": "string"}},
        "candidate_insights": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "enum": ["memory", "claude_md", "doc", "skill"],
                    },
                    "insight": {"type": "string"},
                    "evidence": {"type": "string"},
                    "confidence": {
                        "type": "string",
                        "enum": ["low", "medium", "high"],
                    },
                },
                "required": ["target", "insight", "evidence", "confidence"],
            },
        },
    },
    "required": [
        "intent",
        "constraints",
        "discoveries",
        "decisions",
        "friction_summary",
        "candidate_insights",
    ],
}

SYSTEM = """You are a behavioral analyst mining a single Claude Code coding \
session for durable lessons that would make a future agent work better on THIS \
project. You are given a compressed transcript: the human's turns, the friction \
events (denials, corrections, errors), and the assistant's stated decisions.

Extract, grounded ONLY in the transcript:
- intent: one sentence — what the human was trying to accomplish this session.
- constraints: explicit rules/preferences the human stated or enforced.
- discoveries: non-obvious facts about the codebase/tools the agent had to learn.
- decisions: choices made and why.
- friction_summary: each meaningful moment the agent did the wrong thing or got \
corrected, phrased as a lesson ("agent did X, human wanted Y").
- candidate_insights: durable lessons worth persisting. For each, pick target:
    memory   = personal preference / one-off workflow nuance
    claude_md = a rule recurring/important enough to belong in project instructions
    doc      = deeper explanation belonging in a docs file
    skill    = a repeatable procedure worth a skill
  Include the supporting evidence (quote/paraphrase) and a confidence level.
  Only propose insights with real evidence in THIS transcript. If none, return [].

Be terse and concrete. Do not invent anything not supported by the transcript."""


def embed(texts: list[str], *, model: str = DEFAULT_MODEL, url: str = DEFAULT_URL,
          timeout: int = 120) -> list[list[float]]:
    """Embed a batch of strings via ollama /api/embed. Raises on failure so the
    caller can fall back to lexical clustering."""
    payload = {"model": model, "input": texts}
    req = urllib.request.Request(
        f"{url}/api/embed",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read())
    embs = body.get("embeddings")
    if not embs or len(embs) != len(texts):
        raise RuntimeError(f"embed returned {len(embs or [])} for {len(texts)} inputs")
    return embs


def enrich(model_input: str, *, model: str = DEFAULT_MODEL, url: str = DEFAULT_URL,
           timeout: int = 180) -> dict:
    payload = {
        "model": model,
        "stream": False,
        "format": DIGEST_SCHEMA,
        "options": {"temperature": 0.2, "num_ctx": 16384},
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": model_input},
        ],
    }
    req = urllib.request.Request(
        f"{url}/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read())
    content = body.get("message", {}).get("content", "{}")
    try:
        return json.loads(content)
    except Exception:
        # Salvage: find the outermost JSON object.
        start, end = content.find("{"), content.rfind("}")
        if start >= 0 and end > start:
            return json.loads(content[start : end + 1])
        raise
