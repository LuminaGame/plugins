// Diagnose a native server startup crash without attaching to the editor.
#define NOMINMAX
#include <windows.h>
#include <dbghelp.h>
#include <cstdio>
#include <string>

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  std::wstring command = L"\"" + std::wstring(argv[1]) + L"\" --help";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
      DEBUG_ONLY_THIS_PROCESS | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) return 3;
  SymInitialize(process.hProcess, nullptr, TRUE);
  DEBUG_EVENT event{};
  DWORD exit_code = 0;
  bool finished = false;
  DWORD64 image_base = 0;
  while (!finished && WaitForDebugEvent(&event, 30000)) {
    DWORD action = DBG_CONTINUE;
    if (event.dwDebugEventCode == CREATE_PROCESS_DEBUG_EVENT) {
      std::printf("Image base: %p\n", event.u.CreateProcessInfo.lpBaseOfImage);
      image_base = reinterpret_cast<DWORD64>(event.u.CreateProcessInfo.lpBaseOfImage);
      SymLoadModuleExW(process.hProcess, event.u.CreateProcessInfo.hFile, argv[1], nullptr, image_base, 0, nullptr, 0);
      if (event.u.CreateProcessInfo.hFile) CloseHandle(event.u.CreateProcessInfo.hFile);
    } else if (event.dwDebugEventCode == LOAD_DLL_DEBUG_EVENT) {
      if (event.u.LoadDll.hFile) CloseHandle(event.u.LoadDll.hFile);
    } else if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
      auto& exception = event.u.Exception.ExceptionRecord;
      if (exception.ExceptionCode != EXCEPTION_BREAKPOINT) {
        std::printf("Exception: %08lx at %p (first chance %lu)\n", exception.ExceptionCode,
          exception.ExceptionAddress, event.u.Exception.dwFirstChance);
        for (DWORD i = 0; i < exception.NumberParameters; ++i)
          std::printf("Parameter %lu: %llx\n", i, exception.ExceptionInformation[i]);
        if (exception.ExceptionCode == 0xe06d7363 && exception.NumberParameters > 1) {
          DWORD64 object[4]{};
          ReadProcessMemory(process.hProcess, reinterpret_cast<void*>(exception.ExceptionInformation[1]), object, sizeof(object), nullptr);
          char message[512]{};
          ReadProcessMemory(process.hProcess, reinterpret_cast<void*>(object[1]), message, sizeof(message) - 1, nullptr);
          std::printf("Exception message: %s\n", message);
        }
        HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, event.dwThreadId);
        CONTEXT context{};
        context.ContextFlags = CONTEXT_FULL;
        if (thread && GetThreadContext(thread, &context)) {
          DWORD64 stack[256]{};
          ReadProcessMemory(process.hProcess, reinterpret_cast<void*>(context.Rsp), stack, sizeof(stack), nullptr);
          for (auto address : stack) {
            if (address >= image_base && address < image_base + 0x10000000)
              std::printf("Stack image offset: %llx\n", address - image_base);
          }
          STACKFRAME64 frame{};
          frame.AddrPC = {context.Rip, 0, AddrModeFlat};
          frame.AddrFrame = {context.Rbp, 0, AddrModeFlat};
          frame.AddrStack = {context.Rsp, 0, AddrModeFlat};
          for (int i = 0; i < 30; ++i) {
            std::printf("Frame %d: %llx\n", i, frame.AddrPC.Offset);
            if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, process.hProcess, thread,
                &frame, &context, nullptr, SymFunctionTableAccess64, SymGetModuleBase64, nullptr)) break;
          }
        }
        if (thread) CloseHandle(thread);
        action = DBG_EXCEPTION_NOT_HANDLED;
      }
    } else if (event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT) {
      exit_code = event.u.ExitProcess.dwExitCode;
      finished = true;
    }
    ContinueDebugEvent(event.dwProcessId, event.dwThreadId, action);
  }
  if (!finished) TerminateProcess(process.hProcess, 4);
  SymCleanup(process.hProcess);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return static_cast<int>(exit_code);
}
