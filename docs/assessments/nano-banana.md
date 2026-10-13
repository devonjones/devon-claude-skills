# Skill assessment: nano-banana

## Verdict
Ship with fixes — the skill is small and works as documented, but it carried an unused dependency, a wrong import error message, duplicated prompting content, and a documented interactive script Claude cannot drive.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `nano-banana`, 11 chars, `[a-z0-9-]` only, no reserved words |
| description | pass | 490 chars before fix (`sed -n 3p SKILL.md \| wc -c`, minus newline); 304 after |
| SKILL.md body | pass | 203 lines before (`wc -l`); 168 after |
| reference depth | pass | no reference files; SKILL.md links only to scripts |
| TOC on long refs | pass | n/a, no reference file over 100 lines |
| paths | pass | `grep -n '\\' SKILL.md` returned nothing |
| unlinked files | pass | all 5 scripts and requirements.txt are named in SKILL.md |

Inventory: SKILL.md, requirements.txt, scripts/{generate_image,edit_image,compose_images,chat_image,search_grounded_image}.py; plugin.json (description does not repeat the skill description).

## Findings

1. **P1** `scripts/chat_image.py:62` and `SKILL.md:90-105` — The skill presents the interactive chat script as a task workflow, but it blocks on `input()`; Claude's Bash tool cannot drive it (EOF exits immediately). Claude is likely to run it and get nothing. Added a line saying the user runs it in their own terminal and Claude should re-run `edit_image.py` instead. Whether to add a non-interactive multi-turn mode is an owner decision. *(judgement)*
2. **P2** `requirements.txt:3` — `pyyaml` is listed but no file imports it (`grep -rn yaml .` hits only requirements.txt). Remove. *(measured)*
3. **P2** `scripts/compose_images.py:56`, `scripts/edit_image.py:46` — Import error picks the package with `"genai" in str(e)`; a missing `google` module reads "No module named 'google'", so the message wrongly says to install Pillow. Use `e.name == "PIL"`. *(measured: `ImportError.name` is the module name)*
4. **P2** `SKILL.md:183-203` (original) — "Prompting Tips" repeats the prompts already shown in the Logo, Product Mockup, Portrait and Sticker workflows. Delete. *(measured: same strings appear at lines 69, 75, 81, 87 and 187-202)*
5. **P2** `SKILL.md:115-119,129-133` (original) — "Use cases" bullet lists restate the description and the section headings. Delete. *(judgement)*
6. **P2** `SKILL.md:17,25` — `pip install -r requirements.txt` and `python scripts/...` only work from the skill directory, which is not stated; the plugin-installed location is not the cwd. Added a note that paths are relative to the skill directory. *(judgement)*
7. **P2** `SKILL.md:164-181` (original) — The inline editing example uses `os.environ` without `import os` and never shows saving the result. Added `import os`. *(measured)*
8. **P3** `SKILL.md:3` — Description was 490 chars with a feature list ("iterative refinement, aspect ratio control, ...") that adds no trigger terms. Shortened to the trigger terms. *(judgement)*
9. **P3** `SKILL.md:6-8` (original) — Intro sentence repeats the description. Deleted. *(judgement)*
10. **P3** `scripts/chat_image.py:103` — Model replies are printed with the label "Claude:", but the reply is from Gemini. Changed to "Model:". Also dropped a pointless f-prefix on line 101. *(measured)*
11. **P3** `SKILL.md` — No verification step: nothing tells Claude to look at the generated image before reporting success. Added a two-line "Checking Output" section. *(judgement)*
12. **P2** all five scripts — Default size differs per script (generate 1K; compose and search 2K; edit has no `--size`) and the model id `gemini-3-pro-image-preview` is a preview name hardcoded in five places plus SKILL.md. Not wrong, but a model retirement means six edits. Owner decides whether to centralise. *(judgement)*
13. **P2** all five scripts — API errors (quota, safety block, `response.parts` being `None`) and a missing output directory raise raw tracebacks; the no-image case does exit 1 with a message. Adding handling changes script behaviour. *(judgement)*

## Description test
Should trigger: "make me a logo for my coffee shop", "edit this photo to add a sunset", "combine these three product shots into one banner" — yes, each matches named terms (logo, edit photo, combine images).
Should not trigger: "draw a bar chart of this CSV" (the dataviz skill; "infographic" is the only overlap and the CSV chart is not it), "extract frames from a YouTube video" — no, no shared terms. Risk: "refine an image" could match an ordinary Photoshop-style question, low.

## Evaluations
```json
[
  {
    "skills": ["nano-banana"],
    "query": "Make a 16:9 4K banner image of a futuristic motorcycle on Mars and save it as mars.png",
    "files": [],
    "expected_behavior": [
      "Runs generate_image.py with --aspect 16:9 --size 4K and output mars.png",
      "Does not set GEMINI_API_KEY inline or print it",
      "Opens mars.png (Read) or otherwise confirms the file exists before reporting done"
    ]
  },
  {
    "skills": ["nano-banana"],
    "query": "Take photo.png and make the sky stormy, then make the second version a bit darker",
    "files": ["fixtures/photo.png"],
    "expected_behavior": [
      "Uses edit_image.py, not chat_image.py",
      "Second step runs edit_image.py on the first output, not the original",
      "Does not start an interactive session that waits on stdin"
    ]
  },
  {
    "skills": ["nano-banana"],
    "query": "Combine these 15 product photos into one comparison image",
    "files": ["fixtures/p01.png", "fixtures/p15.png"],
    "expected_behavior": [
      "Notes the 14-image limit before or after the script rejects it",
      "Does not silently drop images without telling the user",
      "Runs compose_images.py with a valid subset or asks which to keep"
    ]
  }
]
```
Not run, per instructions (no baseline runs, no image API calls).

## Not assessed
Live API behaviour (model availability, rate limits, `part.as_image()` against the installed google-genai version), and behaviour on Haiku/Sonnet/Opus; the skill was not executed. The Anthropic best-practices page was not fetched.

## Changes made
1. fixed - added a note that `chat_image.py` is for the user's terminal and that Claude should re-run `edit_image.py` for refinement. Non-interactive chat mode left to owner (see 12/13 note below).
2. fixed - removed `pyyaml` from requirements.txt.
3. fixed - `compose_images.py` and `edit_image.py` now choose the package from `e.name == "PIL"`.
4. fixed - deleted the Prompting Tips section.
5. fixed - deleted the two "Use cases" lists and their lead-in sentences.
6. fixed - Requirements section now says paths are relative to the skill directory.
7. fixed - added `import os` to the inline editing example.
8. fixed - description cut to 304 chars of trigger terms.
9. fixed - deleted the intro sentence.
10. fixed - "Claude:" label changed to "Model:", stray f-prefix removed.
11. fixed - added a short "Checking Output" section.
12. left for owner - centralising the preview model id and size defaults is a design choice.
13. left for owner - API/exception handling and output-directory creation change script behaviour.
Also left for owner: a non-interactive multi-turn script (product decision, from finding 1).
