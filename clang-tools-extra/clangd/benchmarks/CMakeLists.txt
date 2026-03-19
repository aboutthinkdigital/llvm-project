if(CLANGD_DECISION_FOREST)
  add_subdirectory(CompletionModel)
endif()

add_benchmark(IndexBenchmark IndexBenchmark.cpp PARTIAL_SOURCES_INTENDED)

target_link_libraries(IndexBenchmark
  PRIVATE
  clangDaemon
  LLVMSupport
  )

add_benchmark(CallHierarchyBenchmark CallHierarchyBenchmark.cpp PARTIAL_SOURCES_INTENDED)

target_link_libraries(CallHierarchyBenchmark
        PRIVATE
        clangDaemon
        LLVMSupport
)
