lpeg = require('lpeg')
mpack = require('mpack')

-- lpeg grammar for building api metadata from a set of header files. It
-- ignores comments and preprocessor commands and parses a very small subset
-- of C prototypes with a limited set of types
P, R, S = lpeg.P, lpeg.R, lpeg.S
C, Ct, Cc, Cg = lpeg.C, lpeg.Ct, lpeg.Cc, lpeg.Cg

any = P(1) -- (consume one character)
letter = R('az', 'AZ') + S('_$')
alpha = letter + R('09')
nl = P('\r\n') + P('\n')
not_nl = any - nl
ws = S(' \t') + nl
fill = ws ^ 0
c_comment = P('//') * (not_nl ^ 0)
c_preproc = P('#') * (not_nl ^ 0)
typed_container =
  (P('ArrayOf(') + P('DictionaryOf(')) * ((any - P(')')) ^ 1) * P(')')
c_id = (
  typed_container +
  (letter * (alpha ^ 0))
)
c_void = P('void')
c_param_type = (
  ((P('Error') * fill * P('*') * fill) * Cc('error')) +
  (C(c_id) * (ws ^ 1))
  )
c_type = (C(c_void) * (ws ^ 1)) + c_param_type
c_param = Ct(c_param_type * C(c_id))
c_param_list = c_param * (fill * (P(',') * fill * c_param) ^ 0)
c_params = Ct(c_void + c_param_list)
c_proto = Ct(
  Cg(c_type, 'return_type') * Cg(c_id, 'name') *
  fill * P('(') * fill * Cg(c_params, 'parameters') * fill * P(')') *
  Cg(Cc(false), 'async') *
  (fill * Cg((P('FUNC_API_ASYNC') * Cc(true)), 'async') ^ -1) *
  (fill * Cg((P('FUNC_API_NOEXPORT') * Cc(true)), 'noexport') ^ -1) *
  (fill * Cg((P('FUNC_API_NOEVAL') * Cc(true)), 'noeval') ^ -1) *
  fill * P(';')
  )
grammar = Ct((c_proto + c_comment + c_preproc + ws) ^ 1)

-- we need at least 4 arguments since the last two are output files
assert(#arg >= 3)
functions = {}

local nvimsrcdir = arg[1]
package.path = nvimsrcdir .. '/?.lua;' .. package.path

-- names of all headers relative to the source root (for inclusion in the
-- generated file)
headers = {}
-- output c file(dispatch function + metadata serialized with msgpack)
outputf = arg[#arg-1]
-- output mpack file (metadata)
mpack_outputf = arg[#arg]

-- set of function names, used to detect duplicates
function_names = {}

-- read each input file, parse and append to the api metadata
for i = 2, #arg - 2 do
  local full_path = arg[i]
  local parts = {}
  for part in string.gmatch(full_path, '[^/]+') do
    parts[#parts + 1] = part
  end
  headers[#headers + 1] = parts[#parts - 1]..'/'..parts[#parts]

  local input = io.open(full_path, 'rb')
  local tmp = grammar:match(input:read('*all'))
  for i = 1, #tmp do
    local fn = tmp[i]
    if not fn.noexport then
      functions[#functions + 1] = tmp[i]
      function_names[fn.name] = true
      if #fn.parameters ~= 0 and fn.parameters[1][2] == 'channel_id' then
        -- this function should receive the channel id
        fn.receives_channel_id = true
        -- remove the parameter since it won't be passed by the api client
        table.remove(fn.parameters, 1)
      end
      if #fn.parameters ~= 0 and fn.parameters[#fn.parameters][1] == 'error' then
        -- function can fail if the last parameter type is 'Error'
        fn.can_fail = true
        -- remove the error parameter, msgpack has it's own special field
        -- for specifying errors
        fn.parameters[#fn.parameters] = nil
      end
    end
  end
  input:close()
end

local function shallowcopy(orig)
  local copy = {}
  for orig_key, orig_value in pairs(orig) do
    copy[orig_key] = orig_value
  end
  return copy
end

local function startswith(String,Start)
  return string.sub(String,1,string.len(Start))==Start
end

-- Export functions under older deprecated names.
-- These will be removed eventually.
local deprecated_aliases = require("api.dispatch_deprecated")
for i,f in ipairs(shallowcopy(functions)) do
  local ismethod = false
  if startswith(f.name, "nvim_buf_") then
    ismethod = true
  elseif startswith(f.name, "nvim_win_") then
    ismethod = true
  elseif startswith(f.name, "nvim_tabpage_") then
    ismethod = true
  elseif not startswith(f.name, "nvim_") then
    f.noeval = true
    f.deprecated_since = 1
  end
  f.method = ismethod
  local newname = deprecated_aliases[f.name]
  if newname ~= nil then
    if function_names[newname] then
      -- duplicate
      print("Function "..f.name.." has deprecated alias\n"
            ..newname.." which has a separate implementation.\n"..
            "Please remove it from src/nvim/api/dispatch_deprecated.lua")
      os.exit(1)
    end
    local newf = shallowcopy(f)
    newf.name = newname
    if newname == "ui_try_resize" then
      -- The return type was incorrectly set to Object in 0.1.5.
      -- Keep it that way for clients that rely on this.
      newf.return_type = "Object"
    end
    newf.impl_name = f.name
    newf.noeval = true
    newf.deprecated_since = 1
    functions[#functions+1] = newf
  end
end


-- start building the output
output = io.open(outputf, 'wb')

output:write([[
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>
#include <msgpack.h>

#include "nvim/map.h"
#include "nvim/log.h"
#include "nvim/vim.h"
#include "nvim/msgpack_rpc/helpers.h"
#include "nvim/api/private/dispatch.h"
#include "nvim/api/private/helpers.h"
#include "nvim/api/private/defs.h"
]])

for i = 1, #headers do
  if headers[i]:sub(-12) ~= '.generated.h' then
    output:write('\n#include "nvim/'..headers[i]..'"')
  end
end

output:write([[


static const uint8_t msgpack_metadata[] = {

]])
-- serialize the API metadata using msgpack and embed into the resulting
-- binary for easy querying by clients
packed = mpack.pack(functions)
for i = 1, #packed do
  output:write(string.byte(packed, i)..', ')
  if i % 10 == 0 then
    output:write('\n  ')
  end
end
output:write([[
};

void msgpack_rpc_init_function_metadata(Dictionary *metadata)
{
  msgpack_unpacked unpacked;
  msgpack_unpacked_init(&unpacked);
  if (msgpack_unpack_next(&unpacked,
                          (const char *)msgpack_metadata,
                          sizeof(msgpack_metadata),
                          NULL) != MSGPACK_UNPACK_SUCCESS) {
    abort();
  }
  Object functions;
  msgpack_rpc_to_object(&unpacked.data, &functions);
  msgpack_unpacked_destroy(&unpacked);
  PUT(*metadata, "functions", functions);
}

]])

local function real_type(type)
  local rv = type
  if typed_container:match(rv) then
    if rv:match('Array') then
      rv = 'Array'
    else
      rv = 'Dictionary'
    end
  end
  return rv
end

-- start the handler functions. Visit each function metadata to build the
-- handler function with code generated for validating arguments and calling to
-- the real API.
for i = 1, #functions do
  local fn = functions[i]
  if fn.impl_name == nil then
    local args = {}

    output:write('Object handle_'..fn.name..'(uint64_t channel_id, uint64_t request_id, Array args, Error *error)')
    output:write('\n{')
    output:write('\n  Object ret = NIL;')
    -- Declare/initialize variables that will hold converted arguments
    for j = 1, #fn.parameters do
      local param = fn.parameters[j]
      local converted = 'arg_'..j
      output:write('\n  '..param[1]..' '..converted..';')
    end
    output:write('\n')
    output:write('\n  if (args.size != '..#fn.parameters..') {')
    output:write('\n    snprintf(error->msg, sizeof(error->msg), "Wrong number of arguments: expecting '..#fn.parameters..' but got %zu", args.size);')
    output:write('\n    error->set = true;')
    output:write('\n    goto cleanup;')
    output:write('\n  }\n')

    -- Validation/conversion for each argument
    for j = 1, #fn.parameters do
      local converted, convert_arg, param, arg
      param = fn.parameters[j]
      converted = 'arg_'..j
      local rt = real_type(param[1])
      if rt ~= 'Object' then
        output:write('\n  if (args.items['..(j - 1)..'].type == kObjectType'..rt..') {')
        output:write('\n    '..converted..' = args.items['..(j - 1)..'].data.'..rt:lower()..';')
        if rt:match('^Buffer$') or rt:match('^Window$') or rt:match('^Tabpage$') or rt:match('^Boolean$') then
          -- accept nonnegative integers for Booleans, Buffers, Windows and Tabpages
          output:write('\n  } else if (args.items['..(j - 1)..'].type == kObjectTypeInteger && args.items['..(j - 1)..'].data.integer >= 0) {')
          output:write('\n    '..converted..' = (handle_T)args.items['..(j - 1)..'].data.integer;')
        end
        output:write('\n  } else {')
        output:write('\n    snprintf(error->msg, sizeof(error->msg), "Wrong type for argument '..j..', expecting '..param[1]..'");')
        output:write('\n    error->set = true;')
        output:write('\n    goto cleanup;')
        output:write('\n  }\n')
      else
        output:write('\n  '..converted..' = args.items['..(j - 1)..'];\n')
      end

      args[#args + 1] = converted
    end

    -- function call
    local call_args = table.concat(args, ', ')
    output:write('\n  ')
    if fn.return_type ~= 'void' then
      -- has a return value, prefix the call with a declaration
      output:write(fn.return_type..' rv = ')
    end

    -- write the function name and the opening parenthesis
    output:write(fn.name..'(')

    if fn.receives_channel_id then
      -- if the function receives the channel id, pass it as first argument
      if #args > 0 or fn.can_fail then
        output:write('channel_id, '..call_args)
      else
        output:write('channel_id')
      end
    else
      output:write(call_args)
    end

    if fn.can_fail then
      -- if the function can fail, also pass a pointer to the local error object
      if #args > 0 then
        output:write(', error);\n')
      else
        output:write('error);\n')
      end
      -- and check for the error
      output:write('\n  if (error->set) {')
      output:write('\n    goto cleanup;')
      output:write('\n  }\n')
    else
      output:write(');\n')
    end

    if fn.return_type ~= 'void' then
      output:write('\n  ret = '..string.upper(real_type(fn.return_type))..'_OBJ(rv);')
    end
    output:write('\n\ncleanup:');

    output:write('\n  return ret;\n}\n\n');
  end
end

-- Generate a function that initializes method names with handler functions
output:write([[
static Map(String, MsgpackRpcRequestHandler) *methods = NULL;

void msgpack_rpc_add_method_handler(String method, MsgpackRpcRequestHandler handler)
{
  map_put(String, MsgpackRpcRequestHandler)(methods, method, handler);
}

void msgpack_rpc_init_method_table(void)
{
  methods = map_new(String, MsgpackRpcRequestHandler)();

]])

-- Keep track of the maximum method name length in order to avoid walking
-- strings longer than that when searching for a method handler
local max_fname_len = 0
for i = 1, #functions do
  local fn = functions[i]
  output:write('  msgpack_rpc_add_method_handler('..
               '(String) {.data = "'..fn.name..'", '..
               '.size = sizeof("'..fn.name..'") - 1}, '..
               '(MsgpackRpcRequestHandler) {.fn = handle_'..  (fn.impl_name or fn.name)..
               ', .async = '..tostring(fn.async)..'});\n')

  if #fn.name > max_fname_len then
    max_fname_len = #fn.name
  end
end

output:write('\n}\n\n')

output:write([[
MsgpackRpcRequestHandler msgpack_rpc_get_handler_for(const char *name,
                                                     size_t name_len)
{
  String m = {
    .data=(char *)name,
    .size=MIN(name_len, ]]..max_fname_len..[[)
  };
  MsgpackRpcRequestHandler rv =
    map_get(String, MsgpackRpcRequestHandler)(methods, m);

  if (!rv.fn) {
    rv.fn = msgpack_rpc_handle_missing_method;
  }

  return rv;
}
]])

output:close()

mpack_output = io.open(mpack_outputf, 'wb')
mpack_output:write(packed)
mpack_output:close()
