# Downstream build adapter; leaves the pinned upstream checkout unchanged.
function(lumina_vllm_windows_registration_order)
  if(MSVC)
    set_source_files_properties(
      "${CMAKE_SOURCE_DIR}/src/vllm/model_executor/models/qwen3_5_dense.cpp"
      PROPERTIES COMPILE_OPTIONS
      "/FI${CMAKE_CURRENT_FUNCTION_LIST_DIR}/vllm_windows_registration.h")
  endif()
endfunction()
cmake_language(DEFER CALL lumina_vllm_windows_registration_order)
