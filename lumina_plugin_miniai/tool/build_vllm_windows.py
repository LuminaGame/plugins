"""Build a pinned, native Windows vllm.cpp server with MSVC and Vulkan.

Use an existing checkout: python tool/build_vllm_windows.py --source <checkout>
The checkout is never modified. Build output stays below its build directory.
"""
import argparse
import os
from pathlib import Path
import subprocess
import shutil

REVISION = '6d33ea819debc3c52a068e1d24854ab92c2a85b6'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--install', type=Path)
    parser.add_argument('--model-source', type=Path, help='Reuse a previously downloaded Gemma HF model folder.')
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This builder requires Windows and Visual Studio 2022.')
    source = args.source.resolve()
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        parser.error('Checkout must be pinned to ' + REVISION)
    vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio' / 'Installer' / 'vswhere.exe'
    visual_studio = subprocess.check_output([
        str(vswhere), '-latest', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'], text=True).strip()
    cmake = Path(visual_studio) / 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    if not cmake.is_file():
        parser.error('Install the Visual Studio C++ CMake tools.')
    build = source / 'build-windows-current'
    install = args.install or Path(os.environ['LOCALAPPDATA']) / 'Lumina' / 'vllm_native' / 'runtime'
    # The pinned source has unused Linux NUMA guards in Kolibri on MSVC.
    # Suppress that one warning; retain upstream /W4 /WX for other diagnostics.
    subprocess.run([str(cmake), '-S', str(source), '-B', str(build), '-G', 'Visual Studio 17 2022',
                    '-A', 'x64', '-DVLLM_CPP_CUDA=OFF', '-DVLLM_CPP_METAL=OFF',
                    '-DVLLM_CPP_VULKAN=ON', '-DVLLM_CPP_BUILD_TESTS=OFF', '-DVLLM_CPP_TRITON=OFF',
                    '-DVLLM_CPP_WITH_DIARIZATION=OFF', '-DVLLM_CPP_HF_DOWNLOAD=OFF',
                    '-DCMAKE_PROJECT_INCLUDE=' + str(Path(__file__).with_name('vllm_windows_registration.cmake').resolve()),
                    f'-DCMAKE_CXX_FLAGS=/DWIN32 /D_WINDOWS /GR /EHsc /wd4101 /MP{args.jobs}'], check=True)
    subprocess.run([str(cmake), '--build', str(build), '--config', 'Release',
                    '--target', 'server', '-j', str(args.jobs)], check=True)
    subprocess.run([str(cmake), '--install', str(build), '--config', 'Release',
                    '--component', 'vllm-server', '--prefix', str(install)], check=True)
    binary = install / 'bin' / 'vllm-server.exe'
    subprocess.run([str(binary), '--help'], check=True)
    print('Native server: ' + str(binary), flush=True)
    if args.model_source:
        model = install.parent / 'models' / 'gemma-4-E4B-it'
        model.mkdir(parents=True, exist_ok=True)
        for name in ['config.json', 'tokenizer.json', 'tokenizer_config.json',
                     'generation_config.json', 'chat_template.jinja', 'model.safetensors']:
            source_file = args.model_source / name
            target = model / name
            if target.exists() and source_file.stat().st_size == target.stat().st_size:
                continue
            print('Copying ' + name, flush=True)
            partial = target.with_name(target.name + '.part')
            shutil.copyfile(source_file, partial)
            partial.replace(target)
        print('Native model: ' + str(model), flush=True)


if __name__ == '__main__':
    main()
