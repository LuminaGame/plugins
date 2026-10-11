"""Install pinned Windows Vulkan runtime and Qwen Image 2.1 weights."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.request
import zipfile

TAG = 'master-956-1b0ba10'
RUNTIME = ('sd-master-1b0ba10-bin-win-vulkan-x64.zip', 30123908,
           '9e8b9baff514fe5dfb77e51bf08d85f11e6f10128eac14d4474c87f563309725')
MODELS = [
    ('unsloth/Qwen3-VL-8B-Instruct-GGUF', 'b93a7ee713758252c555be4210c00540df954dc2',
     'mmproj-F16.gguf', 1159030336,
     'd406d03ebabefdef86a2c86bf0c1b65f9e046f7a81c218f25de4931b46a07fc4'),
    ('unsloth/Qwen-Image-2.1-GGUF', '2c31ccd392b367a6637841a143813320a02dff55',
     'qwen-image-2.1-Q4_K_M.gguf', 4199565024,
     '631d532e7ca71e8d90a87c71d3699761a812039d22e3370e87498d87754660fe'),
    ('unsloth/Qwen3-VL-8B-Instruct-GGUF', 'b93a7ee713758252c555be4210c00540df954dc2',
     'Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf', 5148699488,
     'e3d1a6e87c5cb31e054f2c3bc0dd82ffde052f613de5eef3665b7bd33c9b703e'),
    ('unsloth/Qwen-Image-2.1-FP8', 'bb21a8ba7f0371c19ad1f72c82a5e8fc10f39939',
     'vae/qwen_image_2.1_vae_bf16.safetensors', 675508656,
     '71879ffd5321e6d10c3c87513e2b474b1252efa7f3dec2969214a9bf06a6dd5c'),
]


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def download(url, target, size, sha):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size == size and digest(target) == sha:
        print('Verified ' + target.name, flush=True)
        return
    partial = target.with_name(target.name + '.part')
    offset = partial.stat().st_size if partial.exists() else 0
    if offset > size:
        partial.unlink()
        offset = 0
    if offset < size:
        request = urllib.request.Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
        with urllib.request.urlopen(request, timeout=60) as response:
            if offset and response.status != 206:
                offset = 0
            last = 0
            with partial.open('ab' if offset else 'wb') as f:
                while chunk := response.read(1024 * 1024):
                    f.write(chunk)
                    offset += len(chunk)
                    if time.monotonic() - last > 2:
                        print(f'{target.name}: {100 * offset / size:.1f}%', flush=True)
                        last = time.monotonic()
    if partial.stat().st_size != size or digest(partial) != sha:
        partial.unlink()
        raise RuntimeError('Download checksum failed: ' + target.name)
    partial.replace(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    name, size, sha = RUNTIME
    archive = root / 'downloads' / name
    download(f'https://github.com/leejet/stable-diffusion.cpp/releases/download/{TAG}/{name}', archive, size, sha)
    runtime = root / 'runtime'
    runtime.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        for member in z.infolist():
            target = (runtime / member.filename).resolve()
            if not target.is_relative_to(runtime):
                raise RuntimeError('Unsafe archive member')
        z.extractall(runtime)
    for repo, revision, filename, size, sha in MODELS:
        download(f'https://huggingface.co/{repo}/resolve/{revision}/{filename}',
                 root / 'models' / Path(filename).name, size, sha)
    binary = next(runtime.rglob('sd-cli.exe'))
    (root / 'installed.json').write_text(json.dumps({'binary': str(binary), 'tag': TAG}), encoding='utf-8')
    print('Installed Qwen Image 2.1 Q4_K_M', flush=True)


if __name__ == '__main__':
    main()
