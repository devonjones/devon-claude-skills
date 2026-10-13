---
name: nano-banana
description: Generate, edit, and compose images with Google's Gemini 3 Pro Image model (Nano Banana Pro). Use when the user asks to create or edit an image, photo, logo, thumbnail, infographic or product shot, combine up to 14 images, refine an image over several turns, or make an image from live Google Search data.
---

# Nano Banana Pro

## Requirements

- `GEMINI_API_KEY` environment variable set
- Python packages: `google-genai`, `Pillow`

Install dependencies (paths in this skill are relative to the skill directory):
```bash
pip install -r requirements.txt
```

## Quick Start

### Generate an Image

```bash
python scripts/generate_image.py "A cat wearing a wizard hat" cat.png
```

### Edit an Existing Image

```bash
python scripts/edit_image.py photo.png "Add a sunset to the background" edited.png
```

### Compose Multiple Images

```bash
python scripts/compose_images.py "Create a group photo in an office" team.png person1.png person2.png
```

## Available Scripts

| Script | Purpose |
|--------|---------|
| `generate_image.py` | Text-to-image generation |
| `edit_image.py` | Edit/modify existing images |
| `compose_images.py` | Combine up to 14 reference images |
| `chat_image.py` | Interactive multi-turn refinement |
| `search_grounded_image.py` | Generate images with real-time search data |

## Generation Options

### Aspect Ratios
`1:1`, `2:3`, `3:2`, `3:4`, `4:3`, `4:5`, `5:4`, `9:16`, `16:9`, `21:9`

### Resolutions
`1K` (1024px), `2K`, `4K`

### Usage with Options

```bash
python scripts/generate_image.py "Futuristic motorcycle on Mars" mars.png --aspect 16:9 --size 4K
```

## Task Workflows

### Logo Generation

```bash
python scripts/generate_image.py "Clean black-and-white logo with text 'Daily Grind', sans-serif font, coffee bean icon, minimalist style" logo.png --aspect 1:1
```

### Product Mockup

```bash
python scripts/generate_image.py "Studio-lit product photo on polished concrete, 3-point softbox, 45-degree angle, professional e-commerce style" product.png --aspect 4:3 --size 4K
```

### Photorealistic Portrait

```bash
python scripts/generate_image.py "A photorealistic close-up portrait, shot on 85mm lens, golden hour lighting, shallow depth of field, cinematic" portrait.png --size 4K
```

### Stylized Art (Anime/Sticker)

```bash
python scripts/generate_image.py "A kawaii red panda sticker, bold outlines, cel-shading, white background, cute expression" sticker.png
```

### Iterative Design Refinement

`chat_image.py` reads prompts from stdin, so the user runs it in their own terminal; Claude cannot drive it. For refinement from Claude, re-run `edit_image.py` on the previous output.

```bash
python scripts/chat_image.py
```

Then interact:
```
> Create a logo for 'Acme Corp'
[Image generated]
> Make the text bolder and add a blue gradient
[Refined image]
> save acme_logo.png
```

### Real-Time Data Visualization

```bash
python scripts/search_grounded_image.py "Visualize today's weather in Tokyo as an infographic" tokyo_weather.png --aspect 9:16
```

### Multi-Image Composition

```bash
python scripts/compose_images.py "Create a product comparison shot with these items side by side, professional lighting" comparison.png item1.png item2.png item3.png --aspect 16:9
```

## Inline Python Usage

For integration in larger scripts:

```python
import os
from google import genai
from google.genai import types

client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])

response = client.models.generate_content(
    model="gemini-3-pro-image-preview",
    contents=["A serene mountain landscape at dawn"],
    config=types.GenerateContentConfig(
        response_modalities=['TEXT', 'IMAGE'],
        image_config=types.ImageConfig(
            aspect_ratio="16:9",
            image_size="2K"
        )
    )
)

for part in response.parts:
    if part.inline_data:
        image = part.as_image()
        image.save("landscape.png")
```

### Editing with Inline Code

```python
import os
from PIL import Image
from google import genai
from google.genai import types

client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
img = Image.open("input.png")

response = client.models.generate_content(
    model="gemini-3-pro-image-preview",
    contents=["Add dramatic clouds to the sky", img],
    config=types.GenerateContentConfig(
        response_modalities=['TEXT', 'IMAGE']
    )
)
```

## Checking Output

Open each generated file with the Read tool to confirm it matches the request; if not, adjust the prompt and re-run.
