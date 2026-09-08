# SPDX-License-Identifier: GPL-3.0-only
execute_process(COMMAND "${NM}" -D --undefined-only "${PLUGIN}"
    RESULT_VARIABLE result OUTPUT_VARIABLE symbols ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect plugin symbols: ${error}")
endif()
if(symbols MATCHES "_Z[0-9]+lua_")
    message(FATAL_ERROR "Lua APIs have C++ linkage; wrap lua.h in extern C")
endif()
foreach(symbol lua_tolstring lua_pushstring lua_pushboolean)
    if(NOT symbols MATCHES " U ${symbol}([@\n]|$)")
        message(FATAL_ERROR "Missing C-linkage Lua reference: ${symbol}")
    endif()
endforeach()
