// MSVC initializes this provider before user-segment alias registrations.
// Tev1 resolves the Qwen3.5 registration during its own global initialization.
// Upstream's unspecified cross-translation-unit ordering can otherwise throw
// before main() on native Windows, including for --help.
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4073)
#pragma init_seg(lib)
#pragma warning(pop)
#endif
