# Trellis Image Studio

An optional extension for `trellis_plugin` 0.2+. Mini AI continues using Gemma
through vllm.cpp; this extension uses **stable-diffusion.cpp** for image creation.

Enable both plugins in Plugin Manager and restart the editor. Open
**Plugins → Trellis Image → Text or Reference to 3D…**. Install the Windows
Vulkan runtime and models, enter a prompt, optionally choose an imported texture
with the editor asset picker, and select **Generate image**. For an edit, describe
the changes to make to the reference texture in the same prompt.

Review the completed image, then select **Approve this image & generate 3D**.
This invokes Trellis and saves its generated mesh into the open project, without
automatically placing an actor. Trellis must have its own executable and models
configured. Image generation alone never starts 3D generation. New generations
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
