add_library(ppic
  m_recon.f90
  m_recon_util.f90
  m_polygon.f90
  m_common.f90
  )

set_target_properties (ppic PROPERTIES
  Fortran_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})

target_include_directories(ppic PUBLIC ${CMAKE_CURRENT_BINARY_DIR})

target_link_libraries(ppic optim)