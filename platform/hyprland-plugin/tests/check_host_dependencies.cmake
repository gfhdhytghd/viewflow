# Plugins must borrow these libraries from the compositor, never load a second
# SONAME with interposing globals and independent destructor registrations.
execute_process(COMMAND "${READELF}" -d "${PLUGIN}"
    RESULT_VARIABLE status OUTPUT_VARIABLE dynamic ERROR_VARIABLE error)
if(NOT status EQUAL 0)
    message(FATAL_ERROR "Cannot inspect plugin: ${error}")
endif()
if(dynamic MATCHES "NEEDED[^\n]*lib(aquamarine|hyprutils|hyprgraphics|hyprcursor|hyprlang)[.]so")
    message(FATAL_ERROR "Plugin directly links a compositor-owned library: ${dynamic}")
endif()
