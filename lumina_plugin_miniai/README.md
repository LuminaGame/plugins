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

  Approval cards offer **Allow**, **Always allow in this chat** and **Deny**; **Stop** cancels a turn.
- **Undo**: one assistant turn is one Edit → Undo step. **Undo this turn** under a turn takes back its level changes (while it is the newest undo step) and restores the files its file tools changed.
- **Plugins → MiniAI** menu: AI Assistant, Connect External Agents…, API Keys…, About MiniAI.
- **Project Settings → Plugins → AI Assistant**: default mode for new chats, preferred model provider, tool groups the assistant never gets, max tool rounds per turn, and project notes added to the assistant's instructions. These are saved in the `.lmproject`.

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

The agent loop tests replay real `/v1/chat/completions` SSE streams from `test/fixtures/sse/`. `dart run tool/record_sse.dart <base url> <model>` records new ones from a running OpenAI-compatible server. The live tests (`test/live_local_model_test.dart`, `test/live_local_manager_test.dart`) run against a real llama-server and MiniCPM5 and are skipped unless both are installed in `miniai/` of Lumina's data directory. They share that one server, which is why the tests run with `--concurrency=1` (as `melos run test` does).

Pack the plugin for the marketplace with `dart run tool/pack_plugin.dart` (`build/pack/lumina_plugin_miniai-<version>.zip`); see the [repository README](../README.md#packing-a-plugin-for-the-marketplace) for its options.

## License

MIT (see [LICENSE](LICENSE)). llama.cpp (MIT) and the MiniCPM5 model weights are downloaded from their publishers at run time and keep their own licenses.
