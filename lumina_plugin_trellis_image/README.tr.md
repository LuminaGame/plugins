# Trellis Image Studio

`trellis_plugin` 0.2+ için ek eklenti. Mini AI, Gemma'yı vllm.cpp üzerinden
kullanmaya devam eder; bu eklenti görsel üretiminde **stable-diffusion.cpp** kullanır.

Plugin Manager'da iki eklentiyi de etkinleştirin ve editörü yeniden başlatın.
**Plugins → Trellis Image → Text or Reference to 3D…** menüsünü açın. Windows
Vulkan çalışma zamanını ve modelleri kurun, isteminizi yazın; isterseniz editörün
asset picker'ından içe aktarılmış bir texture seçip **Generate image** düğmesine
basın. Düzenleme için referansa uygulanacak değişiklikleri aynı istemde tarif edin.

Tamamlanan görseli inceleyip **Approve this image & generate 3D** düğmesine basın.
Trellis oluşan mesh'i açık projeye kaydeder; sahneye otomatik aktör yerleştirmez.
Trellis'in kendi çalıştırılabilir dosyası ve modelleri önceden ayarlanmalıdır.
Görsel üretimi tek başına 3D üretimini başlatmaz. Yeni üretim eski görseli
geçersiz kılar; onayda görsel dosyasının değişmediği de kontrol edilir.

Windows kurulumu yaklaşık 11 GB indirir, sabit sürüm ve SHA-256 doğrulaması
kullanır; kesilen indirmeler devam eder. Dosyalar Lumina'nın kullanıcı verileri
altındaki `qwen_image/` klasörüne kaydedilir. **Cancel current job**, sahip olunan
indirme/görsel sürecini veya Trellis işini iptal eder. Trellis üretimi, bloklayan
bir MCP çağrısı yerine asenkron ilerleme olaylarıyla izlenir.
Hatalar ve native çıkış bilgileri panelde gösterilir.
Native süreç editörden ayrı çalışır.

Modeller: `unsloth/Qwen-Image-2.1-GGUF` **Q4_K_M**, önerilen
`Qwen3-VL-8B-Instruct-UD-Q4_K_XL` kodlayıcı, Qwen Image 2.1 BF16 VAE ve referans
düzenlemeleri için F16 vision projector.
Varsayılanlar: 1024×1024, Euler, 20 adım, CFG 6, seed 42. Kodlayıcı ve VAE
CPU'da çalışır; model offload VRAM kullanımını azaltır. Vulkan GPU indeksi 0'dır;
makinenizde kullanılacak GPU'yu seçin. Diğer platformlarda uyumlu bir `sd-cli`
ve aynı model klasörü düzeni kullanılabilir; otomatik kurulum şimdilik Windows içindir.

`lumina_plugin_trellis_image.generate_image` MCP aracı bir görsel taslağı üretir
ve durumunu bildirir. Onay MCP aracı olarak sunulmaz; arayüzden verilir.

Kaynaklar: [Qwen modeli ve tarifi](https://huggingface.co/unsloth/Qwen-Image-2.1-GGUF),
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp).
