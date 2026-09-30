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

  Onay kartları **Allow**, **Always allow in this chat** ve **Deny** seçeneklerini sunar; **Stop** bir turn'ü iptal eder. Modele her turn'de hangi modda olduğu söylenir (Claude Code'a her mesajda). Plan modunda bir plan önerir ve kullanacağı tool'ların adını verir; değişiklik gerektiren bir Plan turn'ünün altındaki chip tek tıkla **Switch to Ask** sunar.
- **Tool seçimi**: küçük bir model yalnızca isteğinin işaret ettiği tool gruplarını alır; İngilizce, Türkçe, İspanyolca, Almanca ve Fransızca kelimelerden ("sahneye küp ekle", "oyunu oynat ve test et", "ekran görüntüsü al"). Hiçbirine uymayan bir istek level, asset ve view tool'larını alır.
- **Bağlam olarak seçim**: mesaj kutusunun üstündeki bir chip editörde neyin seçili olduğunu gösterir ("Divider_Wall · Primitive", "3 actors", bir Content Browser asset'i) ve seçimi canlı izler. Bir sonraki mesajla bağlam olarak gider; ✕ onu yalnızca o mesajdan çıkarır.
- **@ mention'lar**: `@` yazınca projenin asset'leri (tür ikonlarıyla), Content Browser klasörleri ve level'daki aktörler yazdıkça süzülerek listelenir; ↑/↓ gezinir, Enter ya da Tab seçer, Esc kapatır. Model her mention'ın proje-göreli yolunu ya da aktör id'sini alır. Seçim ve mention'lar her provider'a metninizden önce kısa bir `<editor_context>` bloğu olarak gider; chat sizin metninizi ve altında tek satırlık bir özet gösterir.
- **Tool kartları**: her tool çağrısı adını, riskini, durumunu, argümanlarını ve sonucunu gösterir. Görüntü içeren bir sonuç (`viewport_screenshot`, `pie_advance`, `pie_play_for`, `asset_editor_screenshot`) küçük önizlemeler gösterir; birine tıklayınca tam boyutu açılır.
- **Cevaplar** biçimlendirilmiş Markdown olarak gösterilir (başlıklar, listeler, kalın yazı, kopyalama düğmeli kod blokları, tablolar, tarayıcıda açılan linkler).
- **Sorular**: Claude Code size bir şey sorduğunda (AskUserQuestion aracı), araç kartı soruları ve seçenekleri gösterir; birini (izin verilen yerde birkaçını) seçin ya da **Other…** alanına kendi cevabınızı yazın, sonra **Answer**; cevapsız devam etmesi için **Skip**. Araç kartları argümanlarını ve sonuçlarını en fazla 200 px yüksekliğinde, kaydırılabilir kutularda renkli JSON olarak gösterir.
- **Düşünme**: model cevaplamadan önce akıl yürüttüğünde (llama.cpp'nin `reasoning_content`'i, bir `reasoning` alanı, metin içindeki `<think>` etiketleri, Claude Code'un thinking blokları) cevabın üstünde katlanmış tek bir satır olur: düşünürken hareketli noktalarla **Thinking…**, sonra **Thought for N s**. Tıklayınca akıl yürütme akarken okunur; kutu en fazla 100 px yüksekliğindedir ve siz yukarı kaydırmadıkça metnin sonunu izler. Claude Code varsayılan olarak akıl yürütme metnini paylaşmaz; satırı bunu söyler.
- **Undo**: asistanın bir turn'ü tek bir Edit → Undo adımıdır. Bir turn'ün altındaki **Undo this turn**, onun level değişikliklerini geri alır (en yeni undo adımı olduğu sürece) ve dosya tool'larının değiştirdiği dosyaları geri yükler.
- **Plugins → MiniAI** menüsü: AI Assistant, Connect External Agents…, API Keys…, About MiniAI.
- **Project Settings → Plugins → AI Assistant**: yeni chat'ler için varsayılan mode, tercih edilen model provider, editör seçiminin mesajlarla gidip gitmeyeceği, asistana hiç verilmeyecek tool grupları, turn başına en fazla tool round sayısı ve asistanın talimatlarına eklenen proje notları. Bunlar `.lmproject` içine kaydedilir.

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

**Model accepts images**, editor tool'larının döndürdüğü ekran görüntülerine ne olacağını belirler. Açıkken en yeni ikisi modele görüntü olarak gider (tool sonuçlarından sonra bir user mesajında: chat completions API'si tool mesajlarında görüntüye izin vermez); daha eskileri ve görüntü okuyamayan bir model için her görüntü `[image/png 1280×720, 245 KB produced by the tool; not shown to the model]` gibi kısa bir nota dönüşür. Bilinen vision modellerinde (GPT-4o/4.1/5, Claude, Gemini, Llava, Qwen-VL, MiniCPM-V, Pixtral, Gemma 3, …) varsayılan olarak açık, diğerlerinde (paketle gelen MiniCPM5 dahil) kapalıdır; işaretleyerek ya da kaldırarak değiştirebilirsiniz. Bir chat en yeni 12 görüntüsünün piksellerini saklar.

### Claude Code

[Claude Code](https://claude.com/claude-code) kurulu ve giriş yapılmışsa MiniAI onu model olarak çalıştırabilir. Provider dialog'undaki **Claude Code** bölümü bulduğu `claude`'u (`PATH`'te, native installer'ın klasörlerinde, npm'in global klasöründe ya da VS Code extension'ında; veya sizin yazdığınız bir path), versiyonunu ve giriş yapılıp yapılmadığını gösterir; aksi halde kurulum ve giriş ipuçları verir. Bir model seçin (CLI'ın listesi ya da varsayılanı) ve **Use Claude Code**'a tıklayın. MiniAI bunun için asla key istemez ya da saklamaz: CLI sizin kendi Claude Code girişinizle çalışır.

- **Chat başına bir process.** MiniAI proje klasöründe stream-json input ve output ile `claude -p` çalıştırır; böylece bir chat mesajdan mesaja context'ini korur. CLI'ın session id'si chat ile birlikte kaydedilir; editor yeniden başladıktan sonra bir sonraki mesaj `--resume` ile devam eder. Panel `Claude Code · <model> · session <id>` gösterir, cevap yazıldıkça akar ve footer session'ın maliyetini, turn sayısını ve süresini gösterir.
- **Editor tool'ları.** Process editor'ün MCP server'ını kendi `--mcp-config`'i ile alır (Connect External Agents'taki stdio bridge'in aynısı; Connect adımı gerekmez). Tools → AI Agent Access (MCP) açık olmalıdır. Tool çağrıları MiniAI'ın tool kartları olarak görünür.
- **Onaylar.** Claude Code'un her permission isteği MiniAI'a gider (editor'ün MCP server'ına eklediği `permission_prompt` tool'u) ve chat'in moduna uyar: editor tool'ları risklerine göre; Claude Code'un kendi tool'larından Read/Glob/Grep salt okunur, Edit/Write değiştiren, Bash/WebFetch dışarıya uzanan sayılır. **Ask** modunda bir değişiklik onay kartında bekler. Claude Code ayarlarındaki kendi allow kurallarınız yine geçerlidir ve editor'ün "External agents may run" sınırı bir çağrıyı yine reddedebilir.
- **Undo this turn** Claude Code turn'lerinde de çalışır: editor, chat'in bridge'inden gelen çağrıları turn'e bağlar. Claude Code'un kendi Edit, Write veya Bash tool'larıyla yaptığı değişiklikler takip edilmez; bunları yapan bir turn bunu söyler.
- **Slash command'ler.** `/` yazınca CLI'ın bildirdiği command'ler (built-in'ler ve `.claude/commands` altındakiler) açıklamalarıyla listelenir; birine tıklamak (ya da Enter) onu gönderir, Tab tamamlar. `/context` ve `/usage` model çağrısı olmadan cevap verir, `/compact` session'ı sıkıştırır; CLI'ın tanımadığı bir command modele metin olarak gider.

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

Agent loop test'leri `test/fixtures/sse/` altındaki gerçek `/v1/chat/completions` SSE stream'lerini replay eder. `dart run tool/record_sse.dart <base url> <model>` çalışan bir OpenAI-compatible server'dan yenilerini kaydeder. Claude Code test'leri `test/fixtures/claude_code/` altındaki gerçek session'ları `claude` yerine geçen bir subprocess ile replay eder. `dart tool/record_claude_code.dart --project <dir> --bridge <lumina_ui/bin/lumina_mcp_bridge.dart>` kurulu CLI'ınızla yenilerini kaydeder (girişiniz üzerinden birkaç ucuz `haiku` çağrısı; editor'ün connection dosyası `--config-dir` içinde); hesabı, path'leri ve kendi command'lerinizi bunlardan çıkarır. `test/live_claude_code_test.dart` gerçek CLI üzerinden tek bir küçük prompt gönderir; giriş yapılmış bir `claude` yoksa skip edilir. Live test'ler (`test/live_local_model_test.dart`, `test/live_local_manager_test.dart`) gerçek bir llama-server ve MiniCPM5 ile çalışır; ikisi de Lumina'nın data klasöründeki `miniai/` altında kurulu değilse skip edilir. Hepsi aynı server'ı paylaştığı için test'ler `--concurrency=1` ile çalışır (`melos run test` de öyle yapar).

Plugin'i marketplace için `dart run tool/pack_plugin.dart` ile paketleyin (`build/pack/lumina_plugin_miniai-<version>.zip`); seçenekleri için [repo README'sine](../README.tr.md#pluginimarketplace-için-paketlemek) bakın.

## Lisans

MIT (bkz. [LICENSE](LICENSE)). llama.cpp (MIT) ve MiniCPM5 model ağırlıkları run time'da yayıncılarından indirilir ve kendi lisanslarını korur.
