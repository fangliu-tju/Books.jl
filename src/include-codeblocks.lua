--- include-output.lua – filter to include Julia output
--- Based on include-files.lua – filter to include Markdown files
---

-- pandoc's List type
local List = require 'pandoc.List'

--- Get include auto mode
local include_auto = false
function get_vars (meta)
  if meta['include-auto'] then
    include_auto = true
  end
end

--- Keep last heading level found
local last_heading_level = 0
function update_last_level(header)
  last_heading_level = header.level
end

--- Shift headings in block list by given number
local function shift_headings(blocks, shift_by)
  if not shift_by then
    return blocks
  end

  local shift_headings_filter = {
    Header = function (header)
      header.level = header.level + shift_by
      return header
    end
  }

  return pandoc.walk_block(pandoc.Div(blocks), shift_headings_filter).content
end

--- Return path of the markdown file for the string `s` given by the user.
--- Ensure that this logic corresponds to the logic inside Books.jl.
local md_path
function md_path(s)
  -- Escape all weird characters to ensure they can be in the file.
  -- This yields very weird names, but luckily the code is only internal.
  escaped = s
  escaped = escaped:gsub("%(", "-ob-")
  escaped = escaped:gsub("%)", "-cb-")
  escaped = escaped:gsub("\"", "-dq-")
  escaped = escaped:gsub(":", "-fc-")
  escaped = escaped:gsub(";", "-sc-")
  escaped = escaped:gsub("@", "-ax-")
  path_sep = package.config:sub(1,1)
  path = "_gen" .. path_sep .. escaped .. ".md"
  return path
end

local not_found_error
function not_found_error(line, path, ticks)
  code = ticks .. line .. ticks
  io.stderr:write("Cannot find file for " .. code .. " at " .. path .. "\n")
end

--- Filter function for code blocks
local transclude_codeblock
function transclude_codeblock(cb)
  -- ignore code blocks which are not of class "jl".
  if not cb.classes:includes 'jl' then
    return
  end

  -- Markdown is used if this is nil.
  local format = cb.attributes['format']

  -- Attributes shift headings
  local shift_heading_level_by = 0
  local shift_input = cb.attributes['shift-heading-level-by']
  if shift_input then
    shift_heading_level_by = tonumber(shift_input)
  else
    if include_auto then
      -- Auto shift headings
      shift_heading_level_by = last_heading_level
    end
  end

  --- keep track of level before recusion
  local buffer_last_heading_level = last_heading_level

  local blocks = List:new()
  for line in cb.text:gmatch('[^\n]+') do
    if line:sub(1,2) ~= '//' then

      path = md_path(line)
      if 60 < path:len() then
        msg = "ERROR: The text `" .. line .. "` is too long to be converted to a filename"
        msg = { pandoc.CodeBlock(msg) }
        blocks:extend(msg)
        -- Lua has no continue.
        goto skip_to_next
      end

      local fh = io.open(path)
      if not fh then
        not_found_error(line, path, '```')
        suggestion = "Did you run `gen(; M)` where `M = YourModule`?\n"
        msg = "ERROR: Cannot find file at " .. path .. " for `" .. line .. "`."
        msg = msg .. ' ' .. suggestion
        msg = { pandoc.CodeBlock(msg) }
        blocks:extend(msg)
      else
        local text = fh:read("*a")
        local contents = pandoc.read(text, format).blocks
        last_heading_level = 0
        -- recursive transclusion
        contents = pandoc.walk_block(
          -- Here, the contents is added as an Any block.
          -- Then, the filter is applied again recursively because
          -- the included file could contain an include again!
          pandoc.Div(contents),
          { Header = update_last_level, CodeBlock = transclude }
          ).content
        --- reset to level before recursion
        last_heading_level = buffer_last_heading_level
        contents = shift_headings(contents, shift_heading_level_by)
        -- Note that contents has type List.
        blocks:extend(contents)
        fh:close()
      end
    end
    ::skip_to_next::
  end
  return blocks
end

local startswith
function startswith(s, start)
   return string.sub(s, 1, s.len(start)) == start
end

--- Filter function for inline code
local transclude_code
function transclude_code(c)
  -- ignore code blocks which do not start with "jl".
  if not startswith(c.text, 'jl ') then
    return
  end

  line = c.text
  line = line:sub(4)
  path = md_path(line)

  local fh = io.open(path)
  if not fh then
    not_found_error(line, path, '`')
    suggestion = "Did you run `gen(; M)` where `M = YourModule`?"
    msg = "ERROR: Cannot find file at " .. path .. " for `" .. line .. "`."
    msg = msg .. ' ' .. suggestion
    c.text = msg
  else
    text = fh:read("*a")
    -- To retain ticks, use `c.text = text` and `return c`.
    -- This conversion to a list is essential.
    return { pandoc.Str(text) }
  end

  return c
end

return {
  { Meta = get_vars },
  {
    Header = update_last_level,
    CodeBlock = transclude_codeblock,
    Code = transclude_code
  }
}
