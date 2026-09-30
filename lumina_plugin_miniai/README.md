[Türkçe](README.tr.md)

# MiniAI (lumina_plugin_miniai)

An AI assistant inside Lumina Studio. You chat with a local or cloud model, and the assistant works on your project through the editor's MCP tools: it can inspect the level, place and change actors, edit files, and so on, with your approval. Started from the plugin wizard's editor panel template.

## What it adds to Lumina Studio

- **AI toolbar button** (right of Blueprints) that opens the **AI Assistant** panel in the right dock. The button spins while MiniAI works, shows how many tool calls wait for approval, and turns red after a failed turn or a crashed local server.
- **AI Assistant panel**: the conversation, a composer, the model chip, and a live count of the editor tools the assistant can use. **New chat** and **History** (search over titles and content, rename, pin, delete).
- **Approval modes** per chat:

  | Mode | Behaviour |
  |---|---|
  | Plan | reads and looks around; changes nothing |
  | Ask | asks before every change |
  | Accept edits | makes undoable edits; asks before deleting or reaching outside |
  | Auto | runs every tool without asking |

  Approval cards offer **Allow**, **Always allow in this chat** and **Deny**; **Stop** cancels a turn. The model is told its mode every turn (Claude Code in each message). In Plan mode it proposes a plan and names the tools it would use; when a Plan turn needed changes, a chip under it offers **Switch to Ask** in one click.
- **Tool selection**: a small model gets only the tool groups its request points at, from English, Turkish, Spanish, German and French words ("sahneye küp ekle", "oyunu oynat ve test et", "ekran görüntüsü al"); a request that matches none gets the level, asset and view tools.
- **Selection as context**: a chip above the message box shows what is selected in the editor ("Divider_Wall · Primitive", "3 actors", a Content Browser asset) and follows the selection live. It goes with the next message as context; its ✕ leaves it out of that one message.
- **@ mentions**: type `@` for the project's assets (with type icons), Content Browser folders and the level's actors, filtered as you type; ↑/↓ move, Enter or Tab picks, Esc closes. The model gets each mention's project-relative path or actor id. The selection and the mentions reach every provider as a compact `<editor_context>` block before your text; the chat shows your text and a one-line summary under it.
- **Tool cards**: each tool call shows its name, risk, status, arguments and result. A result with images (`viewport_screenshot`, `pie_advance`, `pie_play_for`, `asset_editor_screenshot`) shows small thumbnails; click one to see it full size.
- **Questions**: when Claude Code asks you something (its AskUserQuestion tool), the tool card shows the questions and their options; pick one (or several where allowed) or type an **Other…** answer, then **Answer**, or **Skip** to let it go on without. Tool cards show their arguments and results as coloured JSON in scrolling boxes at most 200 px tall.
- **Thinking**: when the model reasons before it answers (llama.cpp's `reasoning_content`, a `reasoning` field, inline `<think>` tags, Claude Code's thinking blocks), the answer gets one collapsed row: **Thinking…** with animated dots while it thinks, **Thought for N s** after. Click it to read the reasoning as it streams, in a box at most 100 px high that follows the text unless you scroll up. Claude Code does not share its reasoning text by default; its row says so.
- **Undo**: one assistant turn is one Edit → Undo step. **Undo this turn** under a turn takes back its level changes (while it is the newest undo step) and restores the files its file tools changed.
- **Plugins → MiniAI** menu: AI Assistant, Connect External Agents…, API Keys…, About MiniAI.
- **Project Settings → Plugins → AI Assistant**: default mode for new chats, preferred model provider, whether the editor selection goes with messages, tool groups the assistant never gets, max tool rounds per turn, and project notes added to the assistant's instructions. These are saved in the `.lmproject`.

Chats are stored with the project, under `.lumina/plugins/lumina_plugin_miniai/`, and come back when the project reopens.

## Model providers

Open the provider dialog from the model chip in the panel (**Set up a model provider…**).

### Local model (recommended)

One click downloads and installs:

- **llama.cpp b11239** (`llama-server`): the Vulkan build on Windows and Linux, the Metal build on macOS (arm64);
- a **MiniCPM5** GGUF model: 2B Q4_K_M (default, about 1.6 GB), 2B Q8_0, or 1B Q4_K_M (smaller, less reliable tool calls).

Downloads are resumable and checked against pinned sizes and SHA-256 hashes. Everything goes into `miniai/` in Lumina's data directory (`~/.local/share/lumina` on Linux, `%LOCALAPPDATA%\Lumina` on Windows, `~/Library/Application Support/Lumina` on macOS); set `LUMINA_MINIAI_DIR` to use another folder. Layout: `bin/b11239/` (the server), `models/` (the GGUF), `server.log`, `server.pid`.

A second click starts the server on the GPU you pick (by name; by default the one `FILAMENT_GPU` names, else the first) and makes it MiniAI's provider, on `http://127.0.0.1:<port>/v1`. If the server crashes, the AI button turns red with **Restart** and the server log. The server stops with the editor, and a server left behind by a crashed editor is cleaned up on the next start.

### Any OpenAI-compatible endpoint

Instead of the local model, enter a name, a base URL ending in `/v1` (for example `http://127.0.0.1:8080/v1` for your own llama-server, or an Ollama, LM Studio, vLLM, OpenRouter or OpenAI endpoint), a model (**Test connection** lists the server's models) and an optional API key.

**Model accepts images** decides what happens to screenshots the editor tools return. On, the newest two go to the model as images (after the tool results, in a user message: the chat completions API allows no images in tool messages); older ones and every image for a model without vision become a short note such as `[image/png 1280×720, 245 KB produced by the tool; not shown to the model]`. It is on by default for known vision models (GPT-4o/4.1/5, Claude, Gemini, Llava, Qwen-VL, MiniCPM-V, Pixtral, Gemma 3, …) and off otherwise, the bundled MiniCPM5 included; tick or untick it to override. A chat keeps the pixels of its newest 12 images.

### Claude Code

If you have [Claude Code](https://claude.com/claude-code) installed and logged in, MiniAI can run it as its model. The **Claude Code** section of the provider dialog shows the `claude` it found (on `PATH`, in the native installer's folders, npm's global folder or the VS Code extension; or a path you type), its version and whether it is logged in, with install and login hints otherwise. Pick a model (the CLI's list, or its default) and click **Use Claude Code**. MiniAI never asks for or stores a key for it: the CLI runs on your own Claude Code login.

- **One process per chat.** MiniAI runs `claude -p` with stream-json input and output in the project folder, so a chat keeps its context from message to message. The CLI's session id is saved with the chat; after an editor restart the next message continues it with `--resume`. The panel shows `Claude Code · <model> · session <id>`, the answer streams in as it is written, and the footer shows the session's cost, turns and time.
- **Editor tools.** The process gets the editor's MCP server through its own `--mcp-config` (the same stdio bridge as Connect External Agents, so the Connect step is not needed). Tools → AI Agent Access (MCP) must be on. Its tool calls show as MiniAI's tool cards.
- **Approvals.** Every permission request of Claude Code goes to MiniAI (the `permission_prompt` tool it adds to the editor's MCP server) and follows the chat's mode: editor tools by their risk; Claude Code's own tools as Read/Glob/Grep read-only, Edit/Write changing, Bash/WebFetch reaching outside. In **Ask** a change waits on an approval card. Your own allow rules in Claude Code's settings still apply, and the editor's "External agents may run" ceiling can still refuse a call.
- **Undo this turn** works for Claude Code turns too: the editor ties the calls of the chat's bridge to the turn. Edits Claude Code makes with its own Edit, Write or Bash tools are not tracked; a turn that made them says so.
- **Slash commands.** Type `/` for the commands the CLI reports (built-ins and your `.claude/commands`), with their descriptions; click one (or Enter) to send it, Tab to complete it. `/context` and `/usage` answer without a model call, `/compact` compacts the session, and a command the CLI does not know goes to the model as text.

API keys never go into the project, a chat or the log. They are kept in MiniAI's own `credentials.json` in the plugin's per-user data folder (`plugin_data/lumina_plugin_miniai/` in Lumina's data directory), with mode 0600 on Linux and macOS; provider settings without keys go to `providers.json` next to it. For `api.openai.com`, the `OPENAI_API_KEY` environment variable wins over a stored key. **Plugins → MiniAI → API Keys…** shows each provider's key source and the stored keys (masked), with Remove.

## Connect External Agents

**Plugins → MiniAI → Connect External Agents…** registers the editor's MCP server, through its stdio bridge and without a token in the file, with:

- Antigravity: `~/.gemini/config/mcp_config.json`;
- Claude Code: the project's `.mcp.json`.

Other servers in those files are kept, the old file is backed up, and an unreadable file is never overwritten.

## Installing

Get MiniAI from the Lumina Marketplace inside Lumina Studio, or put this folder into one of the plugin roots (the engine's `plugins/`, `<project>/plugins/`, or `plugins/` in Lumina's data directory). Then enable **MiniAI** in **Plugins → Plugin Manager…** and restart the editor so it rebuilds with the plugin registered.

## Development

```bash
flutter test --concurrency=1
```

The agent loop tests replay real `/v1/chat/completions` SSE streams from `test/fixtures/sse/`. `dart run tool/record_sse.dart <base url> <model>` records new ones from a running OpenAI-compatible server.

The Claude Code tests replay real sessions from `test/fixtures/claude_code/` through a subprocess that stands in for `claude`. `dart tool/record_claude_code.dart --project <dir> --bridge <lumina_ui/bin/lumina_mcp_bridge.dart>` records new ones with your installed CLI (a handful of cheap `haiku` calls on your login; the editor's connection file in `--config-dir`); it removes the account, paths and your own commands from them. `test/live_claude_code_test.dart` sends one tiny prompt through the real CLI and is skipped without a logged-in `claude`. The live tests (`test/live_local_model_test.dart`, `test/live_local_manager_test.dart`) run against a real llama-server and MiniCPM5 and are skipped unless both are installed in `miniai/` of Lumina's data directory. They share that one server, which is why the tests run with `--concurrency=1` (as `melos run test` does).

Pack the plugin for the marketplace with `dart run tool/pack_plugin.dart` (`build/pack/lumina_plugin_miniai-<version>.zip`); see the [repository README](../README.md#packing-a-plugin-for-the-marketplace) for its options.

## License

MIT (see [LICENSE](LICENSE)). llama.cpp (MIT) and the MiniCPM5 model weights are downloaded from their publishers at run time and keep their own licenses.
