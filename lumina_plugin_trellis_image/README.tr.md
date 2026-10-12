# Trellis Image Studio

`trellis_plugin` 0.2+ için ek eklenti. Mini AI, Gemma'yı vllm.cpp üzerinden
kullanmaya devam eder; bu eklenti görsel üretiminde **stable-diffusion.cpp** kullanır.

Plugin Manager'da iki eklentiyi de etkinleştirin ve editörü yeniden başlatın.
**Plugins → Trellis Image → Text or Reference to 3D…** menüsünü açın. Windows
Vulkan çalışma zamanını ve modelleri kurun, isteminizi yazın; isterseniz editörün
asset picker'ından içe aktarılmış bir texture seçip **Generate image** düğmesine
basın. Düzenleme için referansa uygulanacak değişiklikleri aynı istemde tarif edin.
Giysi için **Is cloth** kutusunu işaretleyip yalnızca giysiyi yazın (örneğin
"denim jacket with brass buttons"): istem bir ghost-mannequin ürün fotoğrafı
şablonuna sarılır; görsel giysiyi tek başına, içi boş ve giyilmiş 3B hacmiyle,
dik ve kameraya dönük A-pozunda gösterir, böylece Trellis temiz bir giysi mesh'i
üretir. MCP aracı `generate_image` aynı `cloth` bayrağını alır.

Tamamlanan görseli inceleyip **Approve this image & generate 3D** düğmesine basın.
Trellis çalışır; üretilen mesh **henüz kaydedilmez**. Sekmenin içinde etkileşimli
bir 3D görünümde açılır (editörün viewport'u: sol sürükleme döndürür, sağ / orta
sürükleme kaydırır, tekerlek yakınlaştırır; **Lit**, **Unlit** ve **Wireframe**;
vertex renkleri Trellis'in işlediği gibi görünür) ve üçgen, köşe, boyut (cm) ve
dosya boyutunu gösterir. **Save to Project** (varlık adı + proje klasörü, varsayılan
`contents/meshes/trellis`; `.glb`, `.entity.glb` ve bir `.lmas` StaticMesh yazar,
aktör yerleştirmez) seçilene kadar projeye hiçbir şey yazılmaz. **Regenerate**
sonucu atıp aynı onaylı görselden yeniden üretir; **Discard** siler. Sonuç Trellis
eklentisinin geçici klasöründe durur; bu klasör editör kapanınca da temizlenir.

**Simplify** kaydetmeden önce üçgen sayısını azaltır: bir oran (kaydırıcı ya da
%50 / %25 / %10) veya bir üçgen hedefi seçin, **Apply** (Trellis eklenti sürecinde
hesaplanır, 1 M köşeli bir mesh için yaklaşık 2 sn) ve önce → sonra sayılarını
karşılaştırın; **Revert** üretilen mesh'i yeniden gösterir. Sadeleştirici vertex
renklerini, UV'leri, normalleri ve açık kenarları korur (Trellis'in meshoptimizer
kenar çöktürmesi; sayılar onun README'sinde). Save gösterilen mesh'i yazar. Her
sonucu sadeleştirmek için sol paneldeki **Simplify after 3D generation: target
triangles** alanını doldurun; Revert yine tam mesh'e döner. Trellis'in kendi
çalıştırılabilir dosyası ve modelleri önceden ayarlanmalıdır (Trellis 3D 0.3+).
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
