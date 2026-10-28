local M = {}
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'
local log = require 'minuet.log'
local stats = require 'minuet.stats'

function M.openai_get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

--- Whether the server cut the generation at the token limit (finish_reason ==
--- 'length'). Handles both a single non-streamed JSON body and an SSE stream
--- (where the reason arrives on the final content chunk).
---@param stdout string?
---@return boolean
local function hit_token_limit(stdout)
    if type(stdout) ~= 'string' or stdout == '' then
        return false
    end
    local ok, decoded = pcall(vim.json.decode, stdout)
    if ok and type(decoded) == 'table' then
        local choice = type(decoded.choices) == 'table' and decoded.choices[1]
        return type(choice) == 'table' and choice.finish_reason == 'length'
    end
    for _, line in ipairs(vim.split(stdout, '\n', { plain = true })) do
        line = line:gsub('^data:%s*', '')
        local chunk_ok, chunk = pcall(vim.json.decode, line)
        if chunk_ok and type(chunk) == 'table' and type(chunk.choices) == 'table' then
            local choice = chunk.choices[1]
            if type(choice) == 'table' and choice.finish_reason == 'length' then
                return true
            end
        end
    end
    return false
end

local function prepare_fim_items(items, context, cfg)
    local filtered_items = items
    if cfg.fim_filter_context then
        filtered_items = common.filter_context_sequences_in_items(items, context, cfg)
    end
    return vim.tbl_filter(function(x)
        return type(x) == 'string' and x:find '%S'
    end, filtered_items)
end

---@param options table
---@param context table
---@param callback function
---@param cfg? table Effective config (defaults to global).
function M.complete_openai_base(options, context, callback, cfg)
    local config = cfg or require('minuet').config

    common.terminate_all_jobs()

    local ctx = utils.make_chat_llm_shot(context, options.chat_input)
    ctx = common.create_chat_messages_from_list(ctx)

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(few_shots, 1, { role = 'system', content = system })
    vim.list_extend(few_shots, ctx)

    local data = {
        model = options.model,
        messages = few_shots,
        stream = options.stream,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }
    local transformed_data = common.apply_transforms(options.transform, options.end_point, headers, data)

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        return
    end

    local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file, config)

    local provider_name = 'openai_compatible'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local new_job = common.start_job(config.curl_cmd, args, {
        on_exit = function(_, result)
            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                model = options.model,
                name = options.name,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(result, data_file, options.name, M.openai_get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(result, data_file, options.name, M.openai_get_text_fn_no_stream)
            end

            if not items_raw then
                callback(nil, true)
                return
            end

            local items = common.parse_completion_items(items_raw, options.name)

            items = common.filter_context_sequences_in_items(items, context, config)

            items = utils.remove_spaces(items)

            callback(items, true)
        end,
        on_spawn_error = function()
            os.remove(data_file)
            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                model = options.model,
                name = options.name,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })
            callback(nil, true)
        end,
    })

    if not new_job then
        return
    end

    utils.run_event('MinuetRequestStarted', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

---@param options table Provider options (already a deepcopy from the caller).
---@param get_text_fn function
---@param context table
---@param callback function
---@param cfg? table Effective config (defaults to global).
function M.complete_openai_fim_base(options, get_text_fn, context, callback, cfg)
    local config = cfg or require('minuet').config

    -- Callers that fire one request per keystroke (virtual text) set
    -- keep_existing_jobs so earlier in-flight requests are not cancelled and can
    -- still return a completion matching what the user types next. cmp / duet
    -- leave it unset and keep the cancel-the-previous-request behavior.
    if not (context.opts and context.opts.keep_existing_jobs) then
        common.terminate_all_jobs()
    end

    local data = {}

    data.model = options.model
    data.stream = options.stream
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after
    local opts = context.opts

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    data.prompt = options.template.prompt(context_before_cursor, context_after_cursor, opts)
    data.suffix = options.template.suffix and options.template.suffix(context_before_cursor, context_after_cursor, opts)
        or nil

    -- Codestral-only: in the spurious-leading-newline window a '\n' stop would
    -- trip on the model's spurious first newline and return nothing, so widen it
    -- to '\n\n' for this request (the leading newline is stripped on the way
    -- out). Gated to codestral via options.strip_spurious_leading_newline.
    local in_newline_quirk = options.strip_spurious_leading_newline
        and utils.is_codestral_spurious_newline_setting(data.prompt, data.suffix)
    if in_newline_quirk then
        data.stop = utils.widen_codestral_newline_stop(data.stop)
    end

    local end_point = options.end_point
    local headers = {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }

    local transformed_data = common.apply_transforms(options.transform, end_point, headers, data)

    local n_completions = config.n_completions
    local data_files = {}
    for _ = 1, n_completions do
        local data_file = utils.make_tmp_file(transformed_data.body)
        if data_file == nil then
            for _, file in ipairs(data_files) do
                os.remove(file)
            end
            return
        end
        table.insert(data_files, data_file)
    end

    -- slots[idx] holds the completion from request idx, kept in send order so
    -- the painted suggestions are biased toward the request we sent first
    -- rather than whichever finished first (with streaming the first to finish
    -- tends to be the shortest, which we do not want to favor).
    local slots = {}
    local arrived = {}
    local finished = 0

    local provider_name = 'openai_fim_compatible'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = n_completions,
        timestamp = timestamp,
    })

    -- Bias toward the first-sent request with a short grace window. We paint as
    -- soon as request #1 has settled or everything is done. If a later-sent
    -- request settles first, we hold its result for up to first_request_grace_ms
    -- for #1 to arrive; once that grace expires we paint what we have, and any
    -- later arrival (including #1, which then jumps back to the front) repaints.
    local grace_ms = config.first_request_grace_ms or 100
    local grace_timer
    local grace_done = false

    local function ordered_items()
        local list = {}
        for i = 1, n_completions do
            if slots[i] ~= nil then
                table.insert(list, slots[i])
            end
        end
        return list
    end

    local function stop_grace()
        if grace_timer then
            pcall(function()
                grace_timer:stop()
                grace_timer:close()
            end)
            grace_timer = nil
        end
    end

    local function finish_request(idx, result)
        if result ~= nil then
            slots[idx] = result
        end
        arrived[idx] = true
        finished = finished + 1

        if arrived[1] or grace_done or finished >= n_completions then
            stop_grace()
            callback(prepare_fim_items(ordered_items(), context, config), finished >= n_completions)
        elseif not grace_timer then
            grace_timer = vim.uv.new_timer()
            grace_timer:start(
                grace_ms,
                0,
                vim.schedule_wrap(function()
                    stop_grace()
                    grace_done = true
                    if finished < n_completions then
                        callback(prepare_fim_items(ordered_items(), context, config), false)
                    end
                end)
            )
        end
    end

    for idx = 1, n_completions do
        local data_file = data_files[idx]
        local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file, config)

        -- Stream partials from the FIRST-SENT request only: its settled result
        -- lands in slot 1, the same completion the display ranks first when the
        -- batch finishes, so a partial painted from it never flips to a
        -- different completion as the remaining requests settle.
        local on_stdout
        local on_partial = context.opts and context.opts.on_stream_partial
        if idx == 1 and options.stream and on_partial then
            local feed = utils.make_sse_accumulator(get_text_fn)
            on_stdout = function(chunk)
                local text = feed(chunk)
                if text == nil then
                    return
                end
                if options.strip_spurious_leading_newline then
                    text = utils.strip_codestral_spurious_newline(text, data.prompt, data.suffix)
                end
                if options.trim_suffix_overlap then
                    text = utils.trim_codestral_suffix_overlap(text, context_after_cursor)
                end
                if text and #text > 0 then
                    on_partial(text)
                end
            end
        end

        local started = log.start()
        local new_job = common.start_job(config.curl_cmd, args, {
            on_stdout = on_stdout,
            ---@param out vim.SystemCompleted
            on_exit = function(_, out)
                local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
                log.record {
                    kind = 'fim',
                    provider = provider_name,
                    name = options.name,
                    model = options.model,
                    endpoint = transformed_data.end_point,
                    request = transformed_data.body,
                    response = out.stdout,
                    code = out.code,
                    stderr = out.stderr,
                    started = started,
                    request_idx = idx,
                    n_requests = n_completions,
                    anchored = (context.opts or {}).anchored or false,
                    would_slide = (context.opts or {}).would_slide or false,
                }
                -- Live in-memory token/cache accounting for :Minuet stats. The
                -- anchor/slide flags carry our *expected* server-cache outcome
                -- (snap-back reuse vs a basically-full KV miss) so the dashboard
                -- can cross it against the server's actual cached_tokens.
                local copts = context.opts or {}
                stats.record {
                    name = options.name,
                    model = options.model,
                    response = out.stdout,
                    elapsed_ms = elapsed_ms,
                    anchored = copts.anchored or false,
                    would_slide = copts.would_slide or false,
                }

                utils.run_event('MinuetRequestFinished', {
                    provider = provider_name,
                    name = options.name,
                    model = options.model,
                    n_requests = n_completions,
                    request_idx = idx,
                    timestamp = timestamp,
                })

                local result

                if options.stream then
                    result = utils.stream_decode(out, data_file, options.name, get_text_fn)
                else
                    result = utils.no_stream_decode(out, data_file, options.name, get_text_fn)
                end

                if options.strip_spurious_leading_newline then
                    result = utils.strip_codestral_spurious_newline(result, data.prompt, data.suffix)
                end

                -- Token-limit cut: everything after the last newline is a
                -- truncated line. Callers walking completions line by line
                -- (context.opts.trim_incomplete_tail_line) must never see it,
                -- so drop it -- or the whole result when the cut landed inside
                -- the first line.
                if result and (context.opts or {}).trim_incomplete_tail_line and hit_token_limit(out.stdout) then
                    result = result:match '^(.*)\n[^\n]*$'
                end

                if options.trim_suffix_overlap then
                    result = utils.trim_codestral_suffix_overlap(result, context_after_cursor)
                end

                finish_request(idx, result)
            end,
            on_spawn_error = function()
                os.remove(data_file)
                utils.run_event('MinuetRequestFinished', {
                    provider = provider_name,
                    name = options.name,
                    model = options.model,
                    n_requests = n_completions,
                    request_idx = idx,
                    timestamp = timestamp,
                })
                finish_request(idx, nil)
            end,
        })

        if new_job then
            utils.run_event('MinuetRequestStarted', {
                provider = provider_name,
                name = options.name,
                model = options.model,
                n_requests = n_completions,
                request_idx = idx,
                timestamp = timestamp,
            })
        end
    end
end

return M
