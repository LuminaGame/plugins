"""Pinned vllm.cpp installer and owned server lifecycle (Linux/WSL/macOS)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import urllib.request

VERSION = '0.0.2'
MODEL_REPO = 'unsloth/gemma-4-E4B-it'
MODEL_REVISION = '4e22d7e59e078e63a14f351efdc5232ed366b621'
FILES = ['config.json', 'tokenizer.json', 'tokenizer_config.json',
         'generation_config.json', 'chat_template.jinja', 'model.safetensors']

def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

def download(url, path, expected=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and expected and file_hash(path) == expected:
        return
    partial = Path(str(path) + '.part')
    received = partial.stat().st_size if partial.exists() else 0
    headers = {'Range': f'bytes={received}-'} if received else {}
    if os.environ.get('HF_TOKEN') and 'huggingface.co' in url:
        headers['Authorization'] = 'Bearer ' + os.environ['HF_TOKEN']
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
        append = received and response.status == 206
        with partial.open('ab' if append else 'wb') as output:
            while chunk := response.read(4 * 1024 * 1024):
                output.write(chunk)
    if expected:
        digest = hashlib.sha256()
        with partial.open('rb') as stream:
            while chunk := stream.read(4 * 1024 * 1024):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            partial.unlink()
            raise RuntimeError('SHA256 mismatch: ' + path.name)
    partial.replace(path)

def state(root):
    return {'binary': str(root / 'runtime' / 'bin' / 'vllm-server'),
            'model': str(root / 'models' / 'gemma-4-E4B-it')}

def install(root, backend):
    import platform
    arch = {'AMD64': 'x86_64', 'arm64': 'aarch64'}.get(platform.machine(), platform.machine())
    lane = f'linux-{arch}-glibc-{backend}'
    if sys.platform == 'darwin':
        lane = 'macos-arm64-metal'
    filename = f'vllm.cpp-{VERSION}-{lane}.tar.gz'
    base = f'https://github.com/localai-org/vllm.cpp/releases/download/v{VERSION}/'
    print('Downloading vllm.cpp ' + VERSION + ' (' + lane + ')', flush=True)
    checksum = urllib.request.urlopen(base + filename + '.sha256', timeout=60).read().decode().split()[0]
    archive = root / filename
    download(base + filename, archive, checksum)
    runtime = root / 'runtime'
    runtime.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as bundle:
        # Releases contain one root directory; strip it while retaining bin/lib.
        members = bundle.getmembers()
        common = members[0].name.split('/')[0]
        for member in members:
            name = member.name
            if name == common:
                continue
            if name.startswith(common + '/'):
                member.name = name[len(common) + 1:]
            bundle.extract(member, runtime, filter='data')
    if backend == 'cuda-fat' and sys.platform.startswith('linux'):
        # Release binaries dynamically link CUDA 13; keep its libraries private
        # to this runtime instead of changing the system CUDA installation.
        dependencies = root / 'cuda'
        if not (dependencies / 'nvidia' / 'cu13' / 'lib' / 'libcublasLt.so.13').exists():
            print('Installing CUDA 13 runtime libraries', flush=True)
            subprocess.run([sys.executable, '-m', 'pip', 'install', '--target', str(dependencies),
                            'nvidia-cuda-runtime==13.0.96', 'nvidia-cublas==13.0.2.14'], check=True)
    install_model(Path(state(root)['model']))
    config = state(root)
    if not Path(config['binary']).is_file():
        raise RuntimeError('Release contains no bin/vllm-server')
    (root / 'installed.json').write_text(json.dumps(config), encoding='utf-8')
    print('INSTALLED ' + json.dumps(config), flush=True)


def install_model(model):
    api = f'https://huggingface.co/api/models/{MODEL_REPO}/revision/{MODEL_REVISION}?blobs=true'
    metadata = json.load(urllib.request.urlopen(api, timeout=60))
    entries = {entry['rfilename']: entry for entry in metadata['siblings']}
    for name in FILES:
        entry = entries[name]
        expected = entry.get('lfs', {}).get('sha256')
        target = model / name
        # Metadata files are pinned by repository revision; weight bytes by SHA256 too.
        if target.exists() and target.stat().st_size == entry.get('size') and not expected:
            continue
        print('Downloading ' + name, flush=True)
        download(f'https://huggingface.co/{MODEL_REPO}/resolve/{MODEL_REVISION}/{name}', target, expected)

def stop(root):
    pidfile = root / 'server.json'
    if not pidfile.exists():
        return
    record = json.loads(pidfile.read_text(encoding='utf-8'))
    pid = record['pid']
    # Never signal a reused PID or an unrelated server.
    proc = Path(f'/proc/{pid}/cmdline')
    matches = proc.exists() and record['binary'].encode() in proc.read_bytes().split(b'\0')
    if sys.platform == 'darwin':
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
        matches = result.returncode == 0 and result.stdout.strip().startswith(record['binary'] + ' ')
    if matches:
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    pidfile.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'model', 'start', 'stop'])
    parser.add_argument('--model-dir', type=Path)
    parser.add_argument('--root', default='~/.local/share/lumina/vllm')
    parser.add_argument('--backend', choices=['cpu', 'cuda-fat', 'vulkan'], default='cuda-fat')
    parser.add_argument('--port', type=int, default=8098)
    parser.add_argument('--context', type=int, default=4096)
    args = parser.parse_args()
    root = Path(args.root).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    if args.action == 'model':
        if args.model_dir is None:
            parser.error('--model-dir is required for model installation')
        install_model(args.model_dir.expanduser().resolve())
    elif args.action == 'install':
        install(root, args.backend)
    elif args.action == 'stop':
        stop(root)
    else:
        stop(root)
        config = json.loads((root / 'installed.json').read_text(encoding='utf-8'))
        command = [config['binary'], '--model', config['model'], '--host', '127.0.0.1',
                   '--port', str(args.port), '--served-model-name', 'gemma-4-E4B-it',
                   '--tool-call-parser', 'gemma4', '--reasoning-parser', 'think_auto',
                   '--max-model-len', str(args.context), '--num-blocks', str((args.context + 31) // 32 + 1),
                   '--max-num-seqs', '1']
        environment = dict(os.environ)
        libraries = sorted({str(path.parent) for path in (root / 'cuda').rglob('*.so*')})
        if libraries:
            environment['LD_LIBRARY_PATH'] = os.pathsep.join(libraries + [environment.get('LD_LIBRARY_PATH', '')])
        child = subprocess.Popen(command, start_new_session=True, env=environment)
        (root / 'server.json').write_text(json.dumps({'pid': child.pid, 'binary': config['binary']}), encoding='utf-8')
        try:
            sys.exit(child.wait())
        finally:
            stop(root)

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Runtime failed: ' + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
