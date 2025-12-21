# Devon's Claude Code Skills Marketplace

Personal collection of Claude Code skills for PR automation and creative tasks.

## Installation

### Step 1: Add the Marketplace

Add this marketplace to Claude Code:

```bash
/plugin marketplace add devon-claude-skills https://github.com/devonjones/devon-claude-skills
```

### Step 2: Install Plugins

Install the plugins you want to use:

```bash
# Install PR review loop
/plugin install pr-review-loop@devon-claude-skills

# Install image generation
/plugin install nano-banana@devon-claude-skills

# Or install both
/plugin install pr-review-loop@devon-claude-skills nano-banana@devon-claude-skills
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

## License

MIT - See [LICENSE](LICENSE) for details.
