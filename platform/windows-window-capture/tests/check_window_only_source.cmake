if(NOT DEFINED SOURCE)
  message(FATAL_ERROR "SOURCE is required")
endif()

file(READ "${SOURCE}" capture_source)
string(FIND "${capture_source}" "CreateForWindow(" create_for_window)
if(create_for_window EQUAL -1)
  message(FATAL_ERROR "WGC source must construct a capture item with CreateForWindow")
endif()

foreach(forbidden IN ITEMS
    "CreateForMonitor("
    "IDXGIOutputDuplication"
    "DuplicateOutput("
    "PrintWindow("
    "BitBlt(")
  string(FIND "${capture_source}" "${forbidden}" forbidden_index)
  if(NOT forbidden_index EQUAL -1)
    message(FATAL_ERROR "window-only WGC source contains forbidden fallback: ${forbidden}")
  endif()
endforeach()
