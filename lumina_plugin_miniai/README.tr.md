[English](README.md)

# MiniAI (lumina_plugin_miniai)

Lumina Studio içinde bir AI asistan. Local ya da cloud bir modelle sohbet edersiniz; asistan da editor'ün MCP tool'ları üzerinden projeniz üzerinde çalışır: onayınızla level'ı inceler, actor yerleştirir ve değiştirir, dosya düzenler vb. Plugin wizard'ının editor panel template'inden başlatıldı.

## Lumina Studio'ya ne ekler

- Right dock'ta **AI Assistant** panelini açan **AI toolbar butonu** (Blueprints'in sağında). Buton MiniAI çalışırken döner, onay bekleyen tool call sayısını gösterir, başarısız bir turn'den ya da çöken local server'dan sonra kırmızıya döner.
- **AI Assistant paneli**: konuşma, composer, model chip'i ve asistanın kullanabildiği editor tool'larının canlı sayısı. **New chat** ve **History** (başlık ve içerikte arama, yeniden adlandırma, pin, silme).
- Chat başına **approval mode'ları**:

  | Mode | Davranış |
  |---|---|
  | Plan | okur ve etrafa bakar; hiçbir şeyi değiştirmez |
  | Ask | her değişiklikten önce sorar |
  | Accept edits | undo edilebilir düzenlemeleri yapar; silmeden ya da dışarıya erişmeden önce sorar |
  | Auto | her tool'u sormadan çalıştırır |

  Onay kartları **Allow**, **Always allow in this chat** ve **Deny** seçeneklerini sunar; **Stop** bir turn'ü iptal eder.
- **Undo**: asistanın bir turn'ü tek bir Edit → Undo adımıdır. Bir turn'ün altındaki **Undo this turn**, onun level değişikliklerini geri alır (en yeni undo adımı olduğu sürece) ve dosya tool'larının değiştirdiği dosyaları geri yükler.
- **Plugins → MiniAI** menüsü: AI Assistant, Connect External Agents…, API Keys…, About MiniAI.
- **Project Settings → Plugins → AI Assistant**: yeni chat'ler için varsayılan mode, tercih edilen model provider, asistana hiç verilmeyecek tool grupları, turn başına en fazla tool round sayısı ve asistanın talimatlarına eklenen proje notları. Bunlar `.lmproject` içine kaydedilir.

Chat'ler projeyle birlikte `.lumina/plugins/lumina_plugin_miniai/` altında saklanır ve proje yeniden açıldığında geri gelir.

## Model provider'ları

Provider dialog'unu paneldeki model chip'inden açın (**Set up a model provider…**).

### Local model (önerilen)

Tek tıkla şunlar indirilip kurulur:

- **llama.cpp b11239** (`llama-server`): Windows ve Linux'ta Vulkan build'i, macOS'ta (arm64) Metal build'i;
- bir **MiniCPM5** GGUF modeli: 2B Q4_K_M (varsayılan, yaklaşık 1.6 GB), 2B Q8_0 ya da 1B Q4_K_M (daha küçük, tool call'ları daha az güvenilir).

Download'lar kaldığı yerden devam eder ve sabitlenmiş boyut ve SHA-256 hash'lerine göre kontrol edilir. Her şey Lumina'nın data klasörü (Linux'ta `~/.local/share/lumina`, Windows'ta `%LOCALAPPDATA%\Lumina`, macOS'ta `~/Library/Application Support/Lumina`) altındaki `miniai/` klasörüne iner; başka bir klasör için `LUMINA_MINIAI_DIR` verin. İçerik: `bin/b11239/` (server), `models/` (GGUF), `server.log`, `server.pid`.

İkinci bir tık server'ı seçtiğiniz GPU'da (isimle; varsayılan olarak `FILAMENT_GPU`'nun gösterdiği, o da yoksa ilki) başlatır ve `http://127.0.0.1:<port>/v1` üzerinden MiniAI'ın provider'ı yapar. Server çökerse AI butonu **Restart** ve server log'uyla kırmızıya döner. Server editor ile birlikte durur; çöken bir editor'ün geride bıraktığı server bir sonraki başlangıçta temizlenir.

### Herhangi bir OpenAI-compatible endpoint

Local model yerine bir isim, `/v1` ile biten bir base URL (örneğin kendi llama-server'ınız için `http://127.0.0.1:8080/v1`, ya da bir Ollama, LM Studio, vLLM, OpenRouter veya OpenAI endpoint'i), bir model (**Test connection** server'ın modellerini listeler) ve opsiyonel bir API key girin.

API key'ler asla projeye, bir chat'e ya da log'a girmez. Plugin'in kullanıcıya özel data klasöründeki (Lumina'nın data klasöründeki `plugin_data/lumina_plugin_miniai/`) MiniAI'a ait `credentials.json` dosyasında tutulur; Linux ve macOS'ta dosya modu 0600'dür. Key içermeyen provider ayarları yanındaki `providers.json` dosyasına gider. `api.openai.com` için `OPENAI_API_KEY` environment variable'ı kayıtlı key'in önüne geçer. **Plugins → MiniAI → API Keys…** her provider'ın key kaynağını ve kayıtlı key'leri (maskelenmiş olarak) Remove seçeneğiyle gösterir.

## Connect External Agents

**Plugins → MiniAI → Connect External Agents…**, editor'ün MCP server'ını stdio bridge'i üzerinden ve dosyaya token yazmadan şunlara kaydeder:

- Antigravity: `~/.gemini/config/mcp_config.json`;
- Claude Code: projenin `.mcp.json` dosyası.

Bu dosyalardaki diğer server'lar korunur, eski dosyanın yedeği alınır ve okunamayan bir dosyanın üzerine asla yazılmaz.

## Kurulum

MiniAI'ı Lumina Studio içinden Lumina Marketplace'ten alın ya da bu klasörü plugin root'larından birine koyun (engine'in `plugins/` klasörü, `<project>/plugins/` ya da Lumina'nın data klasöründeki `plugins/`). Sonra **Plugins → Plugin Manager…** içinde **MiniAI**'ı enable edin ve editor'ü yeniden başlatın; editor plugin register edilmiş halde yeniden build olur.

## Development

```bash
flutter test --concurrency=1
```

Agent loop test'leri `test/fixtures/sse/` altındaki gerçek `/v1/chat/completions` SSE stream'lerini replay eder. `dart run tool/record_sse.dart <base url> <model>` çalışan bir OpenAI-compatible server'dan yenilerini kaydeder. Live test'ler (`test/live_local_model_test.dart`, `test/live_local_manager_test.dart`) gerçek bir llama-server ve MiniCPM5 ile çalışır; ikisi de Lumina'nın data klasöründeki `miniai/` altında kurulu değilse skip edilir. Hepsi aynı server'ı paylaştığı için test'ler `--concurrency=1` ile çalışır (`melos run test` de öyle yapar).

Plugin'i marketplace için `dart run tool/pack_plugin.dart` ile paketleyin (`build/pack/lumina_plugin_miniai-<version>.zip`); seçenekleri için [repo README'sine](../README.tr.md#pluginimarketplace-için-paketlemek) bakın.

## Lisans

MIT (bkz. [LICENSE](LICENSE)). llama.cpp (MIT) ve MiniCPM5 model ağırlıkları run time'da yayıncılarından indirilir ve kendi lisanslarını korur.
