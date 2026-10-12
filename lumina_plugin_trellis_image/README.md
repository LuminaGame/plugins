# Trellis Image Studio

An optional extension for `trellis_plugin` 0.2+. Mini AI continues using Gemma
through vllm.cpp; this extension uses **stable-diffusion.cpp** for image creation.

Enable both plugins in Plugin Manager and restart the editor. Open
**Plugins → Trellis Image → Text or Reference to 3D…**. Install the Windows
Vulkan runtime and models, enter a prompt, optionally choose an imported texture
with the editor asset picker, and select **Generate image**. For an edit, describe
the changes to make to the reference texture in the same prompt.

Review the completed image, then select **Approve this image & generate 3D**.
This invokes Trellis; the generated mesh is **not** saved yet. It opens in an
interactive 3D view inside the tab (the editor's viewport: left drag orbits,
right / middle drag pans, the wheel zooms; **Lit**, **Unlit** and **Wireframe**;
vertex colours show as Trellis baked them) with its triangles, vertices, size
(cm) and file size. Nothing is written into the project until **Save to
Project** (asset name + project folder, default `contents/meshes/trellis`; it
writes `.glb`, `.entity.glb` and a `.lmas` StaticMesh, without placing an actor).
**Regenerate** discards the result and generates again from the same approved
image; **Discard** deletes it. The result lives in the Trellis plugin's temp
folder, which is also cleaned when the editor closes.

**Simplify** reduces the triangle count before saving: choose a ratio (slider,
or 50% / 25% / 10%) or a triangle target, **Apply** (computed in the Trellis
plugin process, about 2 s for a 1 M-vertex mesh) and compare before → after;
**Revert** shows the generated mesh again. The simplifier keeps vertex colours,
UVs, normals and open borders (Trellis' meshoptimizer edge collapse; see its
README for the numbers). Save writes the mesh shown. To simplify every result,
set **Simplify after 3D generation: target triangles** in the left rail; Revert
still returns to the full mesh. Trellis must have its own executable and models
configured (Trellis 3D 0.3+). Image generation alone never starts 3D generation. New generations
invalidate the old draft; the approval checks that the image bytes have not changed.

The Windows installer downloads about 11 GB, uses pinned revisions and SHA-256
checks, and resumes interrupted downloads. Files live under Lumina's per-user
`qwen_image/` directory. **Cancel current job** stops the owned download/image process or cancels the
Trellis job. Trellis generation uses asynchronous progress events, without a
blocking MCP request. Errors and native
exit diagnostics appear in the workspace. The native process runs outside the editor.

Models: `unsloth/Qwen-Image-2.1-GGUF` **Q4_K_M**, the recommended
`Qwen3-VL-8B-Instruct-UD-Q4_K_XL` encoder, the Qwen Image 2.1 BF16 VAE, and the F16 vision projector for reference edits.
Generation defaults: 1024×1024, Euler, 20 steps, CFG 6, seed 42. Encoder/VAE
run on CPU and model offload reduces VRAM usage. The Vulkan device index defaults
to 0; select the intended GPU for the current machine. Other platforms can use
an existing compatible `sd-cli` and the same model directory layout; automatic
installation currently supports Windows only.

The MCP `lumina_plugin_trellis_image.generate_image` tool creates a draft and
reports its state. Approval is available in the UI, not as an MCP tool.

Sources: [Qwen weights and recipe](https://huggingface.co/unsloth/Qwen-Image-2.1-GGUF),
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp).
