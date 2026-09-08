-- Non-streaming OpenAI-compatible chat-completions request for duet NES.
-- Sends a message list + tools, returns the parsed assistant message (with
-- tool_calls / content / reasoning) via callback. Tool-call shape validated
-- live against gpt-oss-120b on OpenRouter.

local common = require 'minuet.duet.backends.common'
local session = require 'minuet.duet.session'
local utils = require 'minuet.duet.utils'
local log = require 'minuet.log'

local M = {}

-- Keeps the newline that terminates the fenced body's last line: the region is
-- shipped to the model as one '\n' per line, and the response echoes that, so
-- eating the terminator here would make a blank last line indistinguishable
-- from no last line at all.
local function strip_markdown_fence(content)
    local fenced = content:match '^%s*```[^\n]*\n(.-)```%s*$'
    if fenced then
        return fenced
    end
    return content
end

local function split_region(content)
    content = strip_markdown_fence(content or '')
    -- The marker may sit alone on the region's last line; drop it before the
    -- terminator so that line survives as a blank one.
    content = content:gsub('<|cursor|>', '')
    if content:sub(-1) == '\n' then
        content = content:sub(1, -2)
    end
    return vim.split(content, '\n', { plain = true })
end

local function trailing_blank_count(lines)
    local n = 0
    for i = #lines, 1, -1 do
        if lines[i] ~= '' then
            break
        end
        n = n + 1
    end
    return n
end

-- Mercury sometimes returns the region with its trailing blank line(s) elided.
-- The region tail is a cursor window boundary, not a syntactic unit, so that
-- deletion is never the edit the user wants: it either rides along with a real
-- edit as a frivolous extra hunk, or is the whole "edit". Put the blanks back;
-- the caller's identity check then collapses the latter case to a no-op.
---@param original_lines string[]
---@param replacement string[]
---@return string[]
local function restore_elided_trailing_blanks(original_lines, replacement)
    local want = trailing_blank_count(original_lines)
    local have = trailing_blank_count(replacement)
    if have >= want then
        return replacement
    end
    local out = vim.deepcopy(replacement)
    for _ = have + 1, want do
        out[#out + 1] = ''
    end
    return out
end

local function request_inception_edit(opts, callback, ctx)
    if not (ctx and ctx.bufnr) then
        callback { error = 'inception_edit requires buffer context' }
        return
    end

    local root = require('minuet').config
    local duet = root.duet
    local prompt, region = session.build_inception_edit_turn(ctx.bufnr, {
        lines_before = opts.lines_before,
        lines_after = opts.lines_after,
        max_editable_lines = opts.max_editable_lines,
        snippet_count = opts.snippet_count,
        snippet_radius = opts.snippet_radius,
        max_siblings = opts.max_siblings,
    })
    local body = {
        model = opts.model,
        messages = { { role = 'user', content = prompt } },
        max_tokens = opts.max_tokens or 1000,
    }
    body = vim.tbl_deep_extend('force', body, opts.optional or {})

    local inspect = {
        kind = 'inception_edit',
        provider = duet.provider,
        model = opts.model,
        endpoint = opts.end_point,
        mode = ctx.mode,
        prompt = prompt,
        request = {
            model = body.model,
            max_tokens = body.max_tokens,
            optional = opts.optional or {},
        },
        region = {
            path = region.path,
            start_row = region.start_row,
            end_row = region.end_row,
            original = table.concat(region.original_lines or {}, '\n'),
        },
        outcome = 'pending',
    }

    local api_key = utils.get_api_key(opts.api_key)
    if not api_key then
        inspect.error = 'duet API key is not set (env ' .. tostring(opts.api_key) .. ')'
        inspect.outcome = 'request setup failed'
        callback { error = inspect.error, inspect = inspect }
        return
    end

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. api_key,
    }
    local data_file = utils.make_tmp_file(body)
    if not data_file then
        inspect.error = 'failed to write request temp file'
        inspect.outcome = 'request setup failed'
        callback { error = inspect.error, inspect = inspect }
        return
    end

    local args = utils.make_curl_args(opts.end_point, headers, data_file, duet.request_timeout)
    local started = log.start()
    common.start_job(root.curl_cmd, args, {
        ---@param out vim.SystemCompleted
        on_exit = function(_, out)
            pcall(os.remove, data_file)
            inspect.code = out.code
            inspect.stderr = out.stderr
            inspect.response_raw = out.stdout
            log.record {
                kind = 'duet_inception',
                provider = duet.provider,
                model = opts.model,
                endpoint = opts.end_point,
                request = body,
                response = out.stdout,
                code = out.code,
                stderr = out.stderr,
                started = started,
            }
            if out.code ~= 0 then
                inspect.error = ('curl exited %s: %s'):format(tostring(out.code), tostring(out.stderr or ''))
                inspect.outcome = 'transport error'
                callback { error = inspect.error, inspect = inspect }
                return
            end
            local ok, decoded = pcall(vim.json.decode, out.stdout or '')
            if not ok or type(decoded) ~= 'table' then
                inspect.error = 'failed to decode response: ' .. tostring((out.stdout or ''):sub(1, 200))
                inspect.outcome = 'decode error'
                callback { error = inspect.error, inspect = inspect }
                return
            end
            inspect.response = decoded
            if decoded.error then
                inspect.error = 'API error: ' .. vim.inspect(decoded.error)
                inspect.outcome = 'api error'
                callback { error = inspect.error, inspect = inspect }
                return
            end
            local choice = decoded.choices and decoded.choices[1]
            local content = choice and choice.message and choice.message.content
            inspect.finish_reason = choice and choice.finish_reason or nil
            if type(content) ~= 'string' then
                inspect.error = 'no editable-region content in response: ' .. tostring((out.stdout or ''):sub(1, 200))
                inspect.outcome = 'malformed response'
                callback { error = inspect.error, inspect = inspect }
                return
            end
            inspect.response_content = content

            -- "None" is Mercury Edit's explicit no-edit signal; otherwise the
            -- response is the rewritten editable region. Keep it as a direct
            -- region replacement; do not translate it through apply_patch, whose
            -- fuzzy matcher can retarget repeated text elsewhere in the buffer.
            local replacement
            if vim.trim(strip_markdown_fence(content)) ~= 'None' then
                replacement = restore_elided_trailing_blanks(region.original_lines or {}, split_region(content))
                inspect.replacement = table.concat(replacement, '\n')
            else
                inspect.replacement = 'None'
            end
            if not replacement or vim.deep_equal(region.original_lines, replacement) then
                inspect.outcome = 'no edit'
                if ctx.mode == 'manual' then
                    inspect.error = 'Mercury Edit returned no change for manual prediction'
                    callback { error = inspect.error, inspect = inspect }
                    return
                end
                callback {
                    message = { role = 'assistant', content = require('minuet').config.duet.session.no_edit_token },
                    inspect = inspect,
                }
                return
            end
            inspect.outcome = 'direct replacement generated'
            callback {
                direct_edit = {
                    region = region,
                    replacement = replacement,
                    content = content,
                },
                inspect = inspect,
            }
        end,
        on_spawn_error = function()
            pcall(os.remove, data_file)
            inspect.error = 'failed to spawn curl'
            inspect.outcome = 'spawn error'
            callback { error = inspect.error, inspect = inspect }
        end,
    })
end

---@param messages table[]
---@param tools table[]
---@param ctx? table
---@param callback fun(result: { message?: table, error?: string })
function M.request(messages, tools, callback, ctx)
    local root = require('minuet').config
    local duet = root.duet
    local provider = duet.provider
    local opts = duet.provider_options[provider]

    if not opts then
        callback { error = 'duet provider has no provider_options: ' .. tostring(provider) }
        return
    end

    if provider == 'inception_edit' then
        request_inception_edit(opts, callback, ctx)
        return
    end

    local api_key = utils.get_api_key(opts.api_key)
    if not api_key then
        callback { error = 'duet API key is not set (env ' .. tostring(opts.api_key) .. ')' }
        return
    end

    local body = {
        model = opts.model,
        messages = messages,
        tools = tools,
        tool_choice = 'auto',
        stream = false,
    }
    body = vim.tbl_deep_extend('force', body, opts.optional or {})

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. api_key,
    }

    -- make_tmp_file json-encodes the table itself; pass the table, not a string.
    local data_file = utils.make_tmp_file(body)
    if not data_file then
        callback { error = 'failed to write request temp file' }
        return
    end

    local args = utils.make_curl_args(opts.end_point, headers, data_file, duet.request_timeout)

    local started = log.start()
    common.start_job(root.curl_cmd, args, {
        ---@param out vim.SystemCompleted
        on_exit = function(_, out)
            pcall(os.remove, data_file)
            log.record {
                kind = 'duet_chat',
                provider = provider,
                model = opts.model,
                endpoint = opts.end_point,
                request = body,
                response = out.stdout,
                code = out.code,
                stderr = out.stderr,
                started = started,
            }
            if out.code ~= 0 then
                callback { error = ('curl exited %s: %s'):format(tostring(out.code), tostring(out.stderr or '')) }
                return
            end
            local ok, decoded = pcall(vim.json.decode, out.stdout or '')
            if not ok or type(decoded) ~= 'table' then
                callback { error = 'failed to decode response: ' .. tostring((out.stdout or ''):sub(1, 200)) }
                return
            end
            if decoded.error then
                callback { error = 'API error: ' .. vim.inspect(decoded.error) }
                return
            end
            local choice = decoded.choices and decoded.choices[1]
            local message = choice and choice.message
            if not message then
                callback { error = 'no message in response: ' .. tostring((out.stdout or ''):sub(1, 200)) }
                return
            end
            callback { message = message }
        end,
        on_spawn_error = function()
            pcall(os.remove, data_file)
            callback { error = 'failed to spawn curl' }
        end,
    })
end

return M
