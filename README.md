# Devon's Claude Code Skills Marketplace

Personal collection of Claude Code skills for PR automation and creative tasks.

## Installation

### Step 1: Add the Marketplace

Add this marketplace to Claude Code:

```bash
/plugin marketplace add devonjones/devon-claude-skills
```

### Step 2: Install Plugins

Install the plugins you want to use:

```bash
# Install PR review loop
/plugin install pr-review-loop@devon-claude-skills

# Install image generation
/plugin install nano-banana@devon-claude-skills

# Install YouTube transcripts
/plugin install youtube-transcript@devon-claude-skills

# Or install all
/plugin install pr-review-loop@devon-claude-skills nano-banana@devon-claude-skills youtube-transcript@devon-claude-skills
```

### Step 3: Verify Installation

Check that the plugins are installed:

```bash
/plugin list
```

The skills will be automatically available for Claude to use.

## Available Plugins

### pr-review-loop

Automate PR review feedback loops with Gemini Code Assist, Cursor Bugbot, and Claude fallback.

**Install:**
```bash
/plugin install pr-review-loop@devon-claude-skills
```

**Features:**
- Autonomous review loop execution as Task agent
- Multi-bot support (Gemini Code Assist, Cursor Bugbot, Claude)
- Automatic comment resolution with reply templates
- Rate limit detection and fallback
- Skeptical review evaluation (not all suggestions should be implemented)
- Diminishing returns detection with "ONE MORE LOOP" verification

**Usage:**
```bash
# Spawn autonomous review agent
Task tool:
  subagent_type: general-purpose
  model: sonnet
  description: PR review loop for #<PR>
  prompt: Execute the PR review feedback loop for PR #<PR>...
```

### nano-banana

Generate, edit, and compose images using Google's Gemini 3 Pro Image model.

**Install:**
```bash
/plugin install nano-banana@devon-claude-skills
```

**Features:**
- Text-to-image generation with aspect ratio control
- Image editing with natural language instructions
- Multi-image composition (up to 14 reference images)
- Real-time data visualization with Google Search grounding
- Support for 1K, 2K, and 4K resolutions

**Usage:**
```bash
# Generate an image
scripts/generate_image.py "a serene landscape" output.png --aspect 16:9

# Edit an existing image
scripts/edit_image.py input.png "add a sunset" output.png

# Compose multiple images
scripts/compose_images.py "combine these" output.png img1.png img2.png img3.png
```

### youtube-transcript

Extract transcripts (auto-generated or uploaded) from YouTube videos.

**Install:**
```bash
/plugin install youtube-transcript@devon-claude-skills
```

**Features:**
- URL parsing for `watch?v=`, `youtu.be/`, `youtube.com/shorts/`, `youtube.com/embed/`, and bare 11-character video IDs
- Plain text or `[MM:SS]` / `[HH:MM:SS]` timestamped output
- Language preference via `--lang`
- Direct file output via `-o PATH`
- Dependencies installed in an ephemeral per-invocation venv via `uv run --script` (no persistent Python install pollution)

**Usage:**
```bash
# Plain transcript to stdout
scripts/get_transcript.py "https://www.youtube.com/watch?v=VIDEO_ID"

# With timestamps
scripts/get_transcript.py "VIDEO_ID" --timestamps

# Specific language, write to a file
scripts/get_transcript.py "VIDEO_ID" --lang en -o transcript.txt
```

## Migration Notice

These skills were previously hosted in separate repositories:
- [`skill-pr-review-loop`](https://github.com/devonjones/skill-pr-review-loop) → Archived, redirects here
- [`skill-nano-banana`](https://github.com/devonjones/skill-nano-banana) → Archived, redirects here

## Prerequisites

### pr-review-loop
- `gh` CLI authenticated with GitHub
- `git` installed
- `pre-commit` (optional, auto-detected)

### nano-banana
- Python 3.8+
- `GEMINI_API_KEY` environment variable
- Dependencies: `pip install google-genai Pillow pyyaml`

### youtube-transcript
- `uv` — installs the Python deps in an ephemeral venv per invocation. Install with `curl -LsSf https://astral.sh/uv/install.sh | sh` or `pip install uv`.
- Network access to `youtube.com`.

## License

MIT - See [LICENSE](LICENSE) for details.
