# Changelog

## Unreleased

- Is cloth: the prompt names a garment and is wrapped in a ghost-mannequin product-photo template (garment alone, hollow, worn 3D shape, upright A-pose); also the `cloth` flag of the `generate_image` MCP tool.

## 0.2.0

- The generated mesh is reviewed before it is saved: an interactive 3D view (orbit, pan, zoom, Lit / Unlit / Wireframe) with triangles, vertices, size and file size; Save to Project (name + folder), Regenerate, Discard. Nothing reaches the project before Save.
- Simplify: ratio or triangle target, Apply / Revert with before / after counts (Trellis' meshoptimizer simplifier, vertex colours and UVs kept); optional simplification after every generation.
- Needs Trellis 3D 0.3+.

## 0.1.0

- Qwen Image 2.1 Q4_K_M image generation and reference editing through stable-diffusion.cpp.
- Separate native process, resumable verified Windows model installation, visible errors.
- Explicit image review and approval before Trellis generates a project mesh.
