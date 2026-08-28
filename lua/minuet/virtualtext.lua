-- referenced from copilot.lua https://github.com/zbirenbaum/copilot.lua
local M = {}
local utils = require 'minuet.utils'
local api = vim.api

M.ns_id = api.nvim_create_namespace 'minuet.virtualtext'
M.augroup = api.nvim_create_augroup('MinuetVirtualText', { clear = true })

if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'MinuetVirtualText' })) then
    api.nvim_set_hl(0, 'MinuetVirtualText', { link = 'Comment' })
end

local internal = {
    augroup = M.augroup,
    ns_id = M.ns_id,
    extmark_id = 1,

    timer = nil,
    context = {},
    is_on_throttle = false,
}

-- Running tally of FIM prefix-pin slides (re-anchors that actually shed the
-- warm leading tokens, as opposed to an anchored reuse or a naturally-pinned
-- window). Printed on each fired request as a behavior watch.
local prefix_slide_count = 0

---@return 'off' | 'unintrusive' | 'full'
local function auto_trigger_mode()
    return vim.b.minuet_virtual_text_auto_trigger_mode or 'off'
end

-- True when auto-trigger should fire at the current cursor position.
-- In 'unintrusive' mode the line text after the cursor must be whitespace-only
-- (or the cursor must be at end of line); otherwise ghost text would overlay
-- existing code.
local function should_auto_trigger()
    local mode = auto_trigger_mode()
    if mode == 'full' then
        return true
    end
    if mode == 'unintrusive' then
        local row, col = unpack(api.nvim_win_get_cursor(0))
        local line = api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
        return line:sub(col + 1):match '^%s*$' ~= nil
    end
    return false
end

local function completion_menu_visible()
    local has_cmp = pcall(require, 'cmp')
    local cmp_visible = false

    local has_blink = pcall(require, 'blink-cmp')
    local blink_visible = false

    if has_cmp then
        local ok, _cmp_visible = pcall(function()
            return require('cmp').core.view:visible()
        end)

        if ok then
            cmp_visible = _cmp_visible
        end
    end

    if has_blink then
        local ok, _blink_visible = pcall(function()
            return require('blink-cmp').is_visible()
        end)

        if ok then
            blink_visible = _blink_visible
        end
    end

    return vim.fn.pumvisible() == 1 or cmp_visible or blink_visible
end

---@param bufnr? integer
---@return minuet.VirtualtextSuggestionContext
local function get_ctx(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local ctx = internal.context[bufnr]
    if not ctx then
        ctx = {}
        internal.context[bufnr] = ctx
    end
    return ctx
end

---@param optional table?
---@return string[]?
local function collect_stop_tokens(optional)
    if type(optional) ~= 'table' then
        return nil
    end

    local raw = optional.stop or optional.stop_sequences
    if type(raw) == 'string' then
        return { raw }
    end
    if type(raw) == 'table' then
        return raw
    end

    return nil
end

---@param optional table?
---@return table?
local function strip_stop_tokens(optional)
    if type(optional) ~= 'table' then
        return optional
    end

    local stripped = vim.deepcopy(optional)
    stripped.stop = nil
    stripped.stop_sequences = nil
    return stripped
end

---@param text string
---@param stop_tokens string[]?
---@return string
local function truncate_at_stop_tokens(text, stop_tokens)
    if type(text) ~= 'string' or not stop_tokens or #stop_tokens == 0 then
        return text
    end

    local cutoff = nil
    for _, token in ipairs(stop_tokens) do
        if type(token) == 'string' and token ~= '' then
            local idx = text:find(token, 1, true)
            if idx and (not cutoff or idx < cutoff) then
                cutoff = idx
            end
        end
    end

    if cutoff then
        return text:sub(1, cutoff - 1)
    end

    return text
end

-- How far the cursor has advanced into a cached completion since its request,
-- or nil when the cached prefix `P` is not compatible with the current
-- before-cursor text. Both strings end at their own cursor; the shared
-- immediate context is what keeps the completion valid.
--   * cur_before starts with P: the window grew as the user typed forward (the
--     prefix start stays put until the buffer exceeds context_window). The
--     chars after P are how far the cursor moved into the completion; the
--     caller keeps only completions beginning with those chars and strips them,
--     so reading a completion once and typing it out leaves the rest shown.
--   * P is a suffix of cur_before: same cursor, the cached window just carried
--     less left context (older context further back is outside the range the
--     model saw). Nothing was typed since -- advance 0.
--   * P longer than cur_before: only valid when the current window is itself
--     truncated (there really is more buffer above) AND P ends with cur_before.
--     Against a complete prefix a longer P is a "future" prediction (it used
--     text no longer before the cursor) -- reject it.
-- A slid window (left context dropped, e.g. cached 'abc' vs current 'bcq') is
-- intentionally a miss: no fuzzy shift.
---@param P string cached lines_before
---@param cur_before string current lines_before
---@param cur_incomplete_before boolean current window left-truncated?
---@return integer? typed_since chars typed since the request, nil if incompatible
local function prefix_typed_since(P, cur_before, cur_incomplete_before)
    if #P <= #cur_before then
        if cur_before:sub(1, #P) == P then
            return #cur_before - #P
        end
        if cur_before:sub(#cur_before - #P + 1) == P then
            return 0
        end
        return nil
    end
    if cur_incomplete_before and P:sub(#P - #cur_before + 1) == cur_before then
        return 0
    end
    return nil
end

-- The cached suffix `S` and the current after-cursor text must agree on their
-- overlap (the shorter is a prefix of the longer). Changes further down, past
-- whichever suffix was actually sent, are outside range and keep the entry
-- compatible.
---@param S string cached lines_after
---@param cur_after string current lines_after
---@return boolean
local function suffix_compatible(S, cur_after)
    return S:sub(1, #cur_after) == cur_after or cur_after:sub(1, #S) == S
end

--- Extract the request parameters that distinguish one cache slot from another.
--- Only fields that affect the generated completions are included (model,
--- non-stop optional fields, max_tokens, etc.). Provider endpoint and API key
--- are excluded. Stop tokens are tracked separately so cache reuse can remain
--- valid across narrower or broader stop constraints.
---@param cfg table effective config (post-override)
---@return table
local function extract_cache_params(cfg)
    local opts = cfg.provider_options[cfg.provider] or {}
    local optional = vim.deepcopy(opts.optional)
    return {
        provider = cfg.provider,
        model = opts.model,
        optional = strip_stop_tokens(optional),
        stop_tokens = collect_stop_tokens(optional),
    }
end

--- Index of the last display line to keep when at most `max_lines` content
--- lines (lines with non-whitespace) may be shown, or nil when nothing needs
--- hiding. Blank lines before the cut are kept: after a line-accept the
--- remainder starts with '\n', and the one line worth showing is the next
--- content line, a single virt_line below the cursor.
---@param display_lines string[] suggestion split on '\n'
---@param max_lines integer? nil disables truncation
---@return integer? cut last display-line index to keep, nil when nothing is hidden
local function display_cut(display_lines, max_lines)
    if not max_lines or max_lines <= 0 or #display_lines <= max_lines then
        return nil
    end
    local content = 0
    for i, line in ipairs(display_lines) do
        if line:find '%S' then
            content = content + 1
            if content >= max_lines then
                return i < #display_lines and i or nil
            end
        end
    end
    return nil
end

--- The rendered portion of a completion under the display cap: the display
--- lines up to display_cut, or the whole completion when nothing is hidden or
--- no cap is active. Two completions with equal visible keys paint identical
--- ghost text, so pooling, lock matching, cycling and the (x/y) counter all
--- treat them as one alternative.
---@param completion string
---@param max_lines integer? the family's display cap (ctx.display_max_lines)
---@return string
local function visible_key(completion, max_lines)
    if not max_lines then
        return completion
    end
    local lines = vim.split(completion, '\n', { plain = true })
    local cut = display_cut(lines, max_lines)
    if not cut then
        return completion
    end
    return table.concat(vim.list_slice(lines, 1, cut), '\n')
end

--- Derive the compatible completions for the current buffer state from
--- ctx.cache, ranked by how much backward prefix context they matched (longer
--- is better: more context means the completion is more likely the genuine
--- continuation, and a longer prefix is also probably warm on the server's KV
--- cache). A cache entry contributes when provider/model, non-stop optional
--- fields and stop tokens are all equal, and its prefix/suffix are content-
--- compatible with the current cursor (see prefix_typed_since /
--- suffix_compatible -- no shift tolerance, no time component).
---
--- Each entry's `typed_since` (how much less context it carries than the
--- current cursor) places it in a band: entries past `hard_limit` are dropped
--- from the cyclable list entirely (kept in cache for a returning cursor);
--- those within the bands are shown with the already-typed head stripped. The
--- second return is how many distinct results are *fresh* (typed_since plus
--- the entry's accept-slid chars <= soft_limit) -- the count callers compare
--- against n_completions to decide whether to keep firing top-up requests.
---
--- Distinctness is judged on the *rendered* portion (visible_key): with a
--- display cap active, completions that only differ past the display cut
--- paint identical ghost text, so they collapse into one cyclable entry --
--- the (x/y) counter only ever promises visibly different alternatives. A
--- collapsed group is represented by its most-context member's full text
--- (that hidden tail is the likeliest genuine continuation, and it is what an
--- accept-walk consumes) and counts as fresh via its freshest member.
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table   output of extract_cache_params for the current request
---@param cur_before string  current lines_before
---@param cur_after string   current lines_after
---@param cur_incomplete_before boolean current window left-truncated?
---@param soft_limit integer fresh/soft boundary (chars of missing context)
---@param hard_limit integer soft/hidden boundary
---@return string[] results, integer n_fresh
local function pool_suggestions(ctx, params, cur_before, cur_after, cur_incomplete_before, soft_limit, hard_limit)
    local max_lines = ctx.display_max_lines
    -- One group per distinct visible key. plen (longest matching prefix seen)
    -- ranks the list, order is a stable first-seen tie-break, drift the
    -- smallest typed_since + slid_chars seen (freshness).
    local groups = {} ---@type table<string, { comp: string, plen: integer, order: integer, drift: integer }>
    local list = {}

    -- Normalise a stop-token list so nil and {} compare equal.
    local function norm_stops(t)
        return (t and #t > 0) and t or nil
    end

    for _, entry in ipairs(ctx.cache or {}) do
        if entry.params.provider ~= params.provider then
            goto continue
        end
        if entry.params.model ~= params.model then
            goto continue
        end
        if not vim.deep_equal(entry.params.optional, params.optional) then
            goto continue
        end
        -- Require identical stop tokens so manual (multi-line) and auto
        -- (single-line) completions do not bleed into each other.
        if not vim.deep_equal(norm_stops(entry.params.stop_tokens), norm_stops(params.stop_tokens)) then
            goto continue
        end
        if type(entry.lines_after) ~= 'string' or type(cur_after) ~= 'string' then
            goto continue
        end
        if type(entry.lines_before) ~= 'string' or type(cur_before) ~= 'string' then
            goto continue
        end
        if not suffix_compatible(entry.lines_after, cur_after) then
            goto continue
        end
        local typed_since = prefix_typed_since(entry.lines_before, cur_before, cur_incomplete_before)
        -- Past the hard limit the entry stays in cache (a returning cursor can
        -- re-show it) but is hidden from the cyclable list.
        if typed_since == nil or typed_since > hard_limit then
            goto continue
        end
        -- Freshness counts the chars the entry was slid by accepts on top of
        -- the typed drift: sliding keeps an entry canonical for display, but
        -- its completions were generated from the pre-accept context, so a
        -- walk past the soft band must stop counting them as fresh -- that is
        -- what lets the accept-path top-up fire for fuller-context results.
        local drift = typed_since + (entry.slid_chars or 0)
        -- The user must have typed exactly the head of a completion for its
        -- remainder to still apply; show only what is left untyped.
        local typed = cur_before:sub(#cur_before - typed_since + 1)

        local plen = #entry.lines_before
        for _, comp in ipairs(entry.completions) do
            if comp:sub(1, typed_since) == typed then
                local effective = truncate_at_stop_tokens(comp:sub(typed_since + 1), entry.params.stop_tokens)
                if #effective > 0 then
                    local key = visible_key(effective, max_lines)
                    local group = groups[key]
                    if not group then
                        group = { comp = effective, plen = plen, order = #list + 1, drift = drift }
                        groups[key] = group
                        table.insert(list, group)
                    else
                        -- A fuller-context member donates its (invisible past
                        -- the cut) tail along with the rank.
                        if plen > group.plen then
                            group.comp = effective
                            group.plen = plen
                        end
                        if drift < group.drift then
                            group.drift = drift
                        end
                    end
                end
            end
        end

        ::continue::
    end

    table.sort(list, function(a, b)
        if a.plen ~= b.plen then
            return a.plen > b.plen
        end
        return a.order < b.order
    end)

    local results = {}
    local n_fresh = 0
    for _, group in ipairs(list) do
        table.insert(results, group.comp)
        if group.drift <= soft_limit then
            n_fresh = n_fresh + 1
        end
    end

    return results, n_fresh
end

--- The cache slot for one (params, prefix, suffix) triple, created empty when
--- this state has none yet. FIM backends fire their callback once per parallel
--- request with the growing accumulated list, so results merge into the slot
--- rather than replacing it.
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table
---@param lines_before string
---@param lines_after string
---@return minuet.CacheEntry
local function cache_entry(ctx, params, lines_before, lines_after)
    ctx.cache = ctx.cache or {}
    for _, entry in ipairs(ctx.cache) do
        if vim.deep_equal(entry.params, params)
            and entry.lines_before == lines_before
            and entry.lines_after == lines_after
        then
            return entry
        end
    end
    local entry = {
        lines_before = lines_before,
        lines_after = lines_after,
        params = params,
        completions = {},
    }
    table.insert(ctx.cache, entry)
    return entry
end

local MAX_LOCKS = 8

--- The lock associated with the current buffer state, if any, plus its untyped
--- remainder. Each lock records the completion shown for a state (set the first
--- time something is shown there, updated when the user cycles). Locks are kept
--- in a small ring so returning to an earlier state still resolves the choice
--- the user left there. Uses the same content-based compatibility as a cache
--- entry, so typing forward through -- or returning to -- a locked state keeps
--- the choice resolvable. Most-recent lock wins when several are compatible.
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table   params of the request whose completions are showing
---@param cur_before string
---@param cur_after string
---@param cur_incomplete_before boolean
---@return table? lock, string? remainder the lock stripped of typed-since text
local function compatible_lock(ctx, params, cur_before, cur_after, cur_incomplete_before)
    local locks = ctx.locks or {}
    for i = #locks, 1, -1 do
        local lock = locks[i]
        -- A lock only applies to its own completion family: a choice cycled
        -- under stop='\n' must not pin over a stop='\n\n' set, etc.
        if vim.deep_equal(lock.params, params) and suffix_compatible(lock.lines_after, cur_after) then
            local typed_since = prefix_typed_since(lock.lines_before, cur_before, cur_incomplete_before)
            if typed_since ~= nil
                and lock.completion:sub(1, typed_since) == cur_before:sub(#cur_before - typed_since + 1)
            then
                return lock, lock.completion:sub(typed_since + 1)
            end
        end
    end
    return nil, nil
end

--- Record `completion` as the lock for the current state, replacing the lock
--- already compatible with this state (e.g. the cycle target supersedes the
--- auto-set first-shown one) or pushing a new ring entry otherwise.
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table
---@param completion string
---@param cur_before string
---@param cur_after string
---@param cur_incomplete_before boolean
local function set_lock(ctx, params, completion, cur_before, cur_after, cur_incomplete_before)
    local lock = compatible_lock(ctx, params, cur_before, cur_after, cur_incomplete_before)
    if lock then
        lock.completion = completion
        lock.lines_before = cur_before
        lock.lines_after = cur_after
    else
        ctx.locks = ctx.locks or {}
        table.insert(
            ctx.locks,
            { completion = completion, params = params, lines_before = cur_before, lines_after = cur_after }
        )
        while #ctx.locks > MAX_LOCKS do
            table.remove(ctx.locks, 1)
        end
    end
end

--- Build the display list for the current state and pick the active index.
--- The locked completion -- the one associated with this buffer state, set the
--- first time something is shown and updated when the user cycles -- stays the
--- displayed choice for as long as its state remains compatible, so leaving and
--- returning to that state re-shows it. It also overrides the hard band: a
--- locked completion the user has slid/typed past the hard limit is kept in the
--- list (appended) so it stays visible, where an unlocked one would be hidden.
--- The lock pins a *visible* choice: it matches the pooled results by rendered
--- portion, so under a display cap the group representative (whose hidden tail
--- may carry fuller context than the lock captured) fills the slot.
--- Otherwise the natural ranking (longest prefix / most context first) decides,
--- and the top result becomes the new lock for this state.
--- Records the current state on ctx so a later cycle can re-lock against it.
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table
---@param cur_before string
---@param cur_after string
---@param cur_incomplete_before boolean
---@param cfg table effective config (for the context bands and defaults)
---@return string[] results, integer choice, integer n_fresh
local function derive_suggestions(ctx, params, cur_before, cur_after, cur_incomplete_before, cfg)
    local vt = cfg.virtualtext or {}
    local soft_limit = vt.cache_soft_chars_ahead or 20
    local hard_limit = vt.cache_max_chars_ahead or 40
    local results, n_fresh =
        pool_suggestions(ctx, params, cur_before, cur_after, cur_incomplete_before, soft_limit, hard_limit)

    ctx.cur_before = cur_before
    ctx.cur_after = cur_after
    ctx.cur_incomplete_before = cur_incomplete_before

    local choice = 1
    local _, pinned = compatible_lock(ctx, params, cur_before, cur_after, cur_incomplete_before)
    -- A lock whose completion the user has fully consumed (accepted or typed
    -- out -- remainder empty) is spent: it must not pin the state to an empty
    -- ghost text. Fall through to the natural ranking instead, whose set_lock
    -- re-locks this state to the next result, replacing the spent lock.
    if pinned ~= nil and #pinned > 0 then
        local pinned_key = visible_key(pinned, ctx.display_max_lines)
        local found
        for i, comp in ipairs(results) do
            if visible_key(comp, ctx.display_max_lines) == pinned_key then
                found = i
                break
            end
        end
        if found then
            choice = found
        else
            -- Locked completion is past the hard band (or otherwise unpooled):
            -- keep it visible regardless, appended after the fresher options.
            table.insert(results, pinned)
            choice = #results
        end
    elseif #results > 0 then
        -- New state with nothing locked yet: the most-context result becomes
        -- this state's lock (so sliding/typing through it keeps it visible).
        set_lock(ctx, params, results[1], cur_before, cur_after, cur_incomplete_before)
    end

    return results, choice, n_fresh
end

---@class minuet.CacheEntry
---@field lines_before string
---@field lines_after string
---@field params table
---@field completions string[]
---@field changedtick? integer buffer tick of the last accept-slide
---@field slid_chars? integer chars the entry has been slid forward by accepts (freshness drift)

---@class minuet.VirtualtextSuggestionContext
---@field suggestions? string[]
---@field choice? integer
---@field shown_choices? table<string, true>
---@field cache? minuet.CacheEntry[]
---@field last_trigger_params? table
---@field last_trigger_overrides? table config patch of the trigger that established the active family
---@field last_trigger_was_manual? boolean
---@field anchors? { params: table, lines_before: string, lines_after: string, is_incomplete_before?: boolean }[]
---@field n_retries? integer
---@field request_generation? integer
---@field in_accept? boolean set around a synchronous accept edit
---@field locks? { completion: string, params: table, lines_before: string, lines_after: string }[] per-state lock ring
---@field cur_before? string before-cursor text of the most recent derive
---@field cur_after? string after-cursor text of the most recent derive
---@field cur_incomplete_before? boolean whether cur_before was left-truncated
---@field display_max_lines? integer render at most this many content lines of the active suggestion (nil = all)
---@field fetch_state_before? string before-cursor text where the current top-up budget started
---@field fetch_params? table params of the current top-up budget's state
---@field fetched_this_state? boolean whether a non-retry request already fired at the current top-up state
---@field distinct_active? boolean a fetch for a not-yet-seen completion is in flight
---@field distinct_silent? boolean the in-flight distinct fetch is a preemptive tail prefetch (no dots, no cycle)
---@field distinct_seen? table<string, true> visible keys of the completions already seen when the distinct fetch started
---@field distinct_attempts? integer requests fired so far for the current distinct fetch
---@field extend_active? string ghost text an in-flight request is continuing past (see the extend path in trigger)
---@field skip_cursor_moved_after_accept? { row: integer, col: integer, changedtick: integer } cursor event caused by accept

-- Provider callbacks capture this token; a *hard* cleanup bumps it so in-flight
-- callbacks cannot repaint ghost text after an explicit dismiss / insert-leave.
-- A param-family switch (a non-retry trigger fired with different stop tokens /
-- model than the active family) also bumps it, so the previous family's
-- in-flight callbacks stop painting and retrying once the user asks for a
-- different variant -- otherwise the two families fight over the one display
-- slot. Concurrent requests of the SAME family fired while typing share one
-- generation (no bump), so each still lands its result in the cache and may
-- repaint if it matches the live cursor; a dismiss invalidates them all at once.
---@param ctx minuet.VirtualtextSuggestionContext
---@return integer
local function bump_request_generation(ctx)
    ctx.request_generation = (ctx.request_generation or 0) + 1
    return ctx.request_generation
end

-- Resets display/active state. ctx.cache and ctx.last_trigger_params are
-- intentionally preserved so cached completions remain available for the next
-- cursor movement or trigger without a round-trip.
---@param ctx minuet.VirtualtextSuggestionContext
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
    ctx.n_retries = nil
    ctx.fetch_state_before = nil
    ctx.fetch_params = nil
    ctx.fetched_this_state = nil
    ctx.distinct_active = nil
    ctx.distinct_silent = nil
    ctx.distinct_seen = nil
    ctx.distinct_attempts = nil
    ctx.extend_active = nil
end

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:stop()
        internal.timer:close()
        internal.timer = nil
    end
end

local function clear_preview()
    api.nvim_buf_del_extmark(0, internal.ns_id, internal.extmark_id)
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function get_current_suggestion(ctx)
    ctx = ctx or get_ctx()

    local ok, choice = pcall(function()
        if not vim.fn.mode():match '^[iR]' or not ctx.suggestions or #ctx.suggestions == 0 then
            return nil
        end

        local choice = ctx.suggestions[ctx.choice]

        return choice
    end)

    if ok then
        return choice
    end

    return nil
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function update_preview(ctx)
    ctx = ctx or get_ctx()

    local suggestion = get_current_suggestion(ctx)
    local display_lines = suggestion and vim.split(suggestion, '\n', { plain = true }) or {}

    clear_preview()

    local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

    if not suggestion or #display_lines == 0 or (not show_on_completion_menu and completion_menu_visible()) then
        return
    end

    -- Display-side line cap: the full (multi-line) suggestion stays intact for
    -- the cache and the accept actions; only the rendering is cut, so the ghost
    -- text never displaces more than the configured number of lines below.
    local cut = display_cut(display_lines, ctx.display_max_lines)
    if cut then
        display_lines = vim.list_slice(display_lines, 1, cut)
    end

    local annot = ''

    -- While a cycle-past-the-last fetch is in flight, show a loading indicator
    -- inside the counter -- e.g. (2/2 ⋯) -- even for a lone suggestion, so the
    -- user knows a fresh, distinct completion is being fetched.
    local n_sug = ctx.suggestions and #ctx.suggestions or 0
    if ctx.distinct_active and not ctx.distinct_silent and n_sug >= 1 then
        annot = '(' .. ctx.choice .. '/' .. n_sug .. ' ⋯)'
    elseif n_sug > 1 then
        annot = '(' .. ctx.choice .. '/' .. n_sug .. ')'
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'

    local extmark = {
        id = internal.extmark_id,
        virt_text = { { display_lines[1], 'MinuetVirtualText' } },
        virt_text_pos = 'inline',
    }

    if #display_lines > 1 then
        extmark.virt_lines = {}
        for i = 2, #display_lines do
            extmark.virt_lines[i - 1] = { { display_lines[i], 'MinuetVirtualText' } }
        end

        if #annot > 0 then
            local last_line = #display_lines - 1
            extmark.virt_lines[last_line][1][1] = extmark.virt_lines[last_line][1][1] .. ' ' .. annot
        end
    elseif #annot > 0 then
        extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
    end

    extmark.hl_mode = 'replace'

    api.nvim_buf_set_extmark(0, internal.ns_id, cursor_line - 1, cursor_col - 1, extmark)

    if not ctx.shown_choices[suggestion] then
        ctx.shown_choices[suggestion] = true
    end
end

---@param ctx? minuet.VirtualtextSuggestionContext
---@param soft? boolean When true, preserve `ctx.last_trigger_was_manual` so a
---subsequent CursorMovedI can revive cached suggestions (e.g. user typed a
---typo that broke the match, then backspaced to realign). Used by the
---auto-cleanup path in on_cursor_moved_i; explicit dismiss and insert/buf
---leave use the default (full clear).
local function cleanup(ctx, soft)
    ctx = ctx or get_ctx()
    stop_timer()
    reset_ctx(ctx)
    -- Only a hard cleanup (explicit dismiss, insert/buf-leave) invalidates
    -- in-flight requests. A soft cleanup is the auto path clearing a no-longer-
    -- matching ghost text mid-typing; bumping the generation there would discard
    -- the results of requests fired for earlier keystrokes, which we now want to
    -- keep so they can still land in the cache and match as the user types on.
    if not soft then
        bump_request_generation(ctx)
        ctx.last_trigger_was_manual = nil
    end
    clear_preview()
end

--- Size the prefix independently of the suffix. utils.get_context splits a
--- single combined budget (context_window) by context_ratio, so the prefix can
--- only ever be context_window*context_ratio. When the user wants a direct
--- prefix size (virtualtext.context_before_chars) decoupled from the suffix
--- (virtualtext.context_after_chars), translate the two into the combined
--- window/ratio that get_context already understands: a window of
--- before + max_suffix split so the before side gets exactly `before`. The
--- per-request suffix is then capped at the constant context_after_chars by the
--- post-anchor pass in trigger. No-op (returns cfg) when context_before_chars
--- is unset -- the legacy single-budget model.
---@param cfg table effective config
---@return table cfg a sizing view of cfg (never mutates the input)
local function sizing_cfg(cfg)
    local vt = cfg.virtualtext or {}
    local before = vt.context_before_chars
    if type(before) ~= 'number' or before <= 0 then
        return cfg
    end
    -- We *pin* (fetch and send) a larger prefix than the floor, so the cursor
    -- can rewind context_back_slack chars and still reuse the same warm anchor
    -- (its [start..cursor] slice stays >= the floor). The floor itself is
    -- `before`; the pinned request size is before + context_back_slack.
    local pin = before + math.max(0, vt.context_back_slack or 0)
    -- Ceiling on the suffix so the combined window still leaves the prefix its
    -- full pin budget. context_after_chars is a constant cap (it must stay
    -- byte-stable across requests -- see the post-anchor pass in trigger).
    local after = vt.context_after_chars
    local max_after
    if type(after) == 'number' then
        max_after = after
    else
        max_after = math.floor(cfg.context_window * (1 - cfg.context_ratio))
    end
    max_after = math.max(0, math.floor(tonumber(max_after) or 0))
    local eff_window = pin + max_after
    return vim.tbl_extend('force', cfg, {
        context_window = eff_window,
        context_ratio = pin / eff_window,
    })
end

--- get_context with the decoupled prefix/suffix sizing applied. All virtualtext
--- sizing must go through this so cached entries (keyed on lines_before/after)
--- stay consistent between the trigger and the cursor-moved cache lookup.
---@param cmp_context table
---@param cfg table
---@param anchor? table
---@return table
local function vt_get_context(cmp_context, cfg, anchor)
    return utils.get_context(cmp_context, sizing_cfg(cfg), anchor)
end

--- Resolve the live context against the same prefix-anchor ring used for
--- requests. This is also used by cache lookups: once a long document fills
--- the prefix budget, a fresh window slides by one character per keystroke,
--- while the request window grows from its fixed anchor. Comparing those two
--- shapes makes matching hand-typed completion text look like a cache miss.
---@param cmp_context table
---@param cfg table
---@param ctx minuet.VirtualtextSuggestionContext
---@param params table
---@return table
local function resolve_context(cmp_context, cfg, ctx, params)
    local vt_cfg = cfg.virtualtext or {}
    local growth_slack = vt_cfg.context_growth_slack or 0
    local divergence_slack = vt_cfg.context_divergence_slack or growth_slack
    local anchor_floor = vt_cfg.context_before_chars

    local context
    if math.max(growth_slack, divergence_slack) > 0 and ctx.anchors then
        for i = #ctx.anchors, 1, -1 do
            local snap = ctx.anchors[i]
            if vim.deep_equal(snap.params, params) then
                local cand = vt_get_context(cmp_context, cfg, {
                    prev_lines_before = snap.lines_before,
                    prev_lines_after = snap.lines_after,
                    growth_slack = growth_slack,
                    divergence_slack = divergence_slack,
                    floor = snap.is_incomplete_before and type(anchor_floor) == 'number' and anchor_floor or nil,
                })
                if cand.opts.anchored then
                    context = cand
                    break
                end
            end
        end
    end
    if not context then
        context = vt_get_context(cmp_context, cfg)
    end

    -- Keep the suffix cap identical for request and lookup contexts too.
    local after_opt = vt_cfg.context_after_chars
    if type(after_opt) == 'number' and after_opt >= 0 then
        local full_after = context.lines_after
        if vim.fn.strchars(full_after) > after_opt then
            context.lines_after = vim.fn.strcharpart(full_after, 0, after_opt)
            context.opts.is_incomplete_after = true
        end
    end

    return context
end

--- The part of `text` still ahead of the live cursor, or nil when `text` no
--- longer applies there. Applies the same content-compatibility rules as the
--- cache pool (suffix agreement, typed-since head match) to a single completion,
--- which is what lets a streamed partial be painted while the user keeps typing.
---@param cfg table effective config
---@param req_before string before-cursor text the completion was requested at
---@param req_after string after-cursor text the completion was requested at
---@param text string
---@return string?
local function live_remainder(cfg, req_before, req_after, text)
    local ctx_now = vt_get_context(utils.make_cmp_context(), cfg)
    if not suffix_compatible(req_after, ctx_now.lines_after) then
        return nil
    end
    local typed_since = prefix_typed_since(req_before, ctx_now.lines_before, ctx_now.opts.is_incomplete_before)
    if typed_since == nil or typed_since >= #text then
        return nil
    end
    if text:sub(1, typed_since) ~= ctx_now.lines_before:sub(#ctx_now.lines_before - typed_since + 1) then
        return nil
    end
    return text:sub(typed_since + 1)
end

---@param bufnr integer
---@param overrides? table Optional partial config patch, deep-merged onto the
---live config for this single request (no global mutation). Use to fire with a
---different provider/model/stop tokens without `change_model`/`change_provider`.
---@param is_retry? boolean When true this is an automatic cache-fill retry;
---n_retries is not reset.
---@param is_manual? boolean When true the request was user-initiated (not the
---auto-trigger debounce path). Manual completions remain visible while typing
---even when auto-trigger is off.
---@param extend? string Ghost text to continue rather than replace: the prompt
---prefix gets it appended and the results are stitched back onto it, so this
---family's completions still start at the real cursor. Used when a manual
---keymap escalates the completion the user is already looking at (see
---`virtualtext.extend_visible`).
local function trigger(bufnr, overrides, is_retry, is_manual, extend)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    utils.notify('Minuet virtual text started', 'verbose')

    local cfg = require('minuet').config
    if overrides then
        cfg = vim.tbl_deep_extend('force', cfg, overrides)
    end

    local ctx = get_ctx(bufnr)

    ctx.cache = ctx.cache or {}

    local params = extract_cache_params(cfg)

    if not is_retry then
        ctx.last_trigger_was_manual = is_manual or false
        -- Switching param-families (e.g. pressing the multi-line keymap while
        -- single-line auto results are showing / still in flight) begins a new
        -- display lineage. Bump the generation so the previous family's
        -- in-flight responses still cache their completions but no longer
        -- repaint or fire retries over the family the user just asked for --
        -- without this the two families' (streaming) callbacks fight over the
        -- single display slot and the ghost text flickers between them.
        if ctx.last_trigger_params ~= nil and not vim.deep_equal(params, ctx.last_trigger_params) then
            bump_request_generation(ctx)
            -- The bump silences a pending extension's callback, so it can no
            -- longer clear this itself.
            ctx.extend_active = nil
        end
    end

    -- Anchor reuse keeps the FIM prompt prefix start byte-identical to a recent
    -- request so the server's KV cache stays warm. We keep a small ring of
    -- recent "snap points": the prefix/suffix captured each time we re-anchored.
    -- While the user types forward the newest snap point keeps matching, so the
    -- prefix just grows from it (the snap stays put -- slack measures chars
    -- typed since the snap). When the newest snap no longer anchors, we look
    -- back through older snap points and snap to the first prefix+suffix pair
    -- that is still buffer-valid. The ring is only searched past its newest
    -- entry when that newest one fails to anchor, i.e. on a snap, not on every
    -- keystroke.
    local cmp_context = utils.make_cmp_context()
    local context = resolve_context(cmp_context, cfg, ctx, params)
    -- Virtual text fires one request per keystroke that misses the cache and
    -- lets them run concurrently, so the backend must NOT terminate the jobs of
    -- earlier in-flight requests: any of them may still return a completion that
    -- matches what the user types next. (cmp / duet leave this unset and keep
    -- the cancel-the-previous-request behavior.)
    context.opts.keep_existing_jobs = true
    local cur_before = context.lines_before
    local cur_after = context.lines_after

    -- Remember which params were active so on_cursor_moved_i can match them, and
    -- the patch that produced them so every top-up fired on behalf of what is on
    -- screen stays in the same family. Without the patch a top-up would re-fire
    -- as the default (auto-trigger) family and repaint the display with its
    -- results under its display cap -- pulling the rug from under a manual
    -- multi-line completion the user is in the middle of accepting.
    ctx.last_trigger_params = params
    ctx.last_trigger_overrides = overrides

    -- Display-side line cap traveling with this trigger family, resolved from
    -- the effective (post-override) config so a manual multi-line keymap can
    -- lift it for its own request (virtualtext = { max_display_lines = false })
    -- while auto/default triggers keep it. Rendering only: the full completion
    -- is cached and accepted as usual.
    local max_display_lines = (cfg.virtualtext or {}).max_display_lines
    ctx.display_max_lines = type(max_display_lines) == 'number' and max_display_lines > 0 and max_display_lines or nil

    -- Line-walking display: a completion the server cut at the token limit
    -- ends in a truncated line, which the walk would eventually surface as if
    -- it were a complete line completion. Ask the backend to trim that tail
    -- before the result reaches the cache, so the pool only ever serves whole
    -- lines. Uncapped (multi-line) triggers keep the raw completion.
    context.opts.trim_incomplete_tail_line = ctx.display_max_lines ~= nil

    -- Show any already-cached suggestions immediately while the request is in
    -- flight (never block display on the request, even when a fresher / more
    -- context-rich response could still arrive).
    local n_completions = cfg.n_completions or 3
    local max_retries = (cfg.virtualtext or {}).max_retries or 6
    local soft_limit = (cfg.virtualtext or {}).cache_soft_chars_ahead or 20
    local hard_limit = (cfg.virtualtext or {}).cache_max_chars_ahead or 40

    -- Extend: this family continues the ghost text the user is looking at
    -- instead of replacing it. Pin the longest completion cached here that
    -- continues that text, seeding the text itself as a completion of this
    -- family when nothing does yet -- it starts at the real cursor like any
    -- other, so it pools, locks and slides normally. The pin is what the paint
    -- below renders: with the cap lifted it is already a reveal (the tail the
    -- cap was hiding), and it holds the display steady, never shrinking, while
    -- the continuation is generated.
    local extend_satisfied = false
    if extend then
        local pooled = pool_suggestions(
            ctx,
            params,
            cur_before,
            cur_after,
            context.opts.is_incomplete_before,
            soft_limit,
            hard_limit
        )
        local best = extend
        for _, comp in ipairs(pooled) do
            if #comp > #best and comp:sub(1, #extend) == extend then
                best = comp
            end
        end
        -- Two ways the request is not worth firing: a continuation generated
        -- earlier is already cached here, or the ghost text runs past this
        -- family's stop token -- by this family's own definition it is already a
        -- whole block, and the pool would cut any continuation off at that stop
        -- anyway, so the request could not produce anything displayable.
        extend_satisfied = best ~= extend or truncate_at_stop_tokens(extend, params.stop_tokens) ~= extend
        if not extend_satisfied then
            -- Nothing cached continues it yet, so the ghost text itself is what
            -- has to hold the display while the continuation is generated.
            local entry = cache_entry(ctx, params, cur_before, cur_after)
            if not vim.tbl_contains(entry.completions, extend) then
                table.insert(entry.completions, extend)
            end
        end
        set_lock(ctx, params, best, cur_before, cur_after, context.opts.is_incomplete_before)
    end

    local cached, choice, n_fresh =
        derive_suggestions(ctx, params, cur_before, cur_after, context.opts.is_incomplete_before, cfg)
    -- During a cycle-past-the-last distinct fetch we keep the user's current
    -- view (the last suggestion + loading dots) on screen rather than snapping
    -- back to the ranked top; the callback swaps in the new distinct completion.
    if #cached > 0 and not ctx.distinct_active then
        ctx.suggestions = cached
        ctx.choice = choice
        ctx.shown_choices = ctx.shown_choices or {}
        update_preview(ctx)
    end

    if extend then
        -- Nothing left to generate: the reveal above is the whole answer, served
        -- from the local cache without a request.
        if extend_satisfied then
            ctx.extend_active = nil
            return
        end
        ctx.extend_active = extend
    end

    -- Per-state top-up budget. The goal is n_completions *fresh* completions
    -- (those with near-full context) for the current buffer state. We start a
    -- fresh budget only when the cursor has moved to a genuinely new state -- the
    -- prefix drifted past the soft band, or the params changed -- so that typing
    -- within one state shares a single budget. Within a state, once a non-retry
    -- request has fired and the retry budget is spent we "move on" rather than
    -- re-hammering a position that refuses to yield distinct fresh completions.
    -- A distinct fetch and an extend deliberately bypass both gates: the bucket
    -- may well be full of completions that are not what the user just asked for
    -- (a not-yet-seen one; a continuation of what is on screen).
    if not is_retry and not ctx.distinct_active and not extend then
        local drift = ctx.fetch_state_before ~= nil
            and vim.deep_equal(ctx.fetch_params, params)
            and prefix_typed_since(ctx.fetch_state_before, cur_before, context.opts.is_incomplete_before)
        if drift == nil or drift == false or drift > soft_limit then
            ctx.fetch_state_before = cur_before
            ctx.fetch_params = params
            ctx.n_retries = 0
            ctx.fetched_this_state = false
        end
        -- Satisfied: enough fresh completions already cached.
        if n_fresh >= n_completions then
            return
        end
        -- Moved on: we already have at least one fresh completion to show, have
        -- spent the whole retry budget at this state-family, and have not moved
        -- to a new position -- so stop re-hammering a spot that will not yield
        -- another distinct fresh completion. When n_fresh is 0 we always keep
        -- trying: the user has nothing yet, and a new keystroke is a new chance.
        if not is_manual and n_fresh >= 1 and ctx.fetched_this_state and (ctx.n_retries or 0) >= max_retries then
            return
        end
        ctx.fetched_this_state = true
    end

    -- Record a snap point only when we actually re-anchored (the chosen window
    -- is a fresh one, not a reuse of an existing snap). Reuses keep growing
    -- from the fixed snap prefix, so the slack measures chars typed since the
    -- snap -- which is what keeps the anchor put during steady typing and lets
    -- it snap only occasionally. We push even if the request later fails: the
    -- server caches what it saw, and a stale snap just misses next time.
    if not context.opts.anchored then
        ctx.anchors = ctx.anchors or {}
        table.insert(ctx.anchors, {
            params = params,
            lines_before = cur_before,
            lines_after = cur_after,
            is_incomplete_before = context.opts.is_incomplete_before,
        })
        local max_anchors = (cfg.virtualtext or {}).max_anchors or 8
        while #ctx.anchors > max_anchors do
            table.remove(ctx.anchors, 1)
        end
    end

    -- Prefix-pin slide watch. Each fired request is either an anchored reuse
    -- (pin held), a re-anchor that naturally pins (prefix at buffer top, no
    -- loss), or a slide (re-anchor that sheds the warm leading tokens). Count
    -- the slides and print the running tally each request so the pin's behavior
    -- is easy to keep an eye on. Skip retries: they re-fire at the same state
    -- and would double-count one keystroke's slide.
    if not is_retry then
        local disp = context.opts.anchored and 'anchored'
            or (context.opts.would_slide and 'slid' or 'pinned')
        if disp == 'slid' then
            prefix_slide_count = prefix_slide_count + 1
        end
        print(string.format('[minuet] prefix pin slides: %d (this: %s)', prefix_slide_count, disp))
    end

    -- The extend request is asked to continue past the ghost text, so the prompt
    -- prefix gets it appended -- after the anchor bookkeeping above, which tracks
    -- buffer content only. It is a pure append at the prefix tail, so the warm
    -- prefix the anchor pinned stays warm; the cache slot and the anchor keep
    -- using the real before-cursor text, and the results are stitched back onto
    -- `extend` in the callback.
    if extend then
        context.lines_before = cur_before .. extend
    end

    local provider = require('minuet.backends.' .. cfg.provider)

    -- Capture (do not bump) the current generation: concurrent in-flight
    -- requests share it, so each one's callback runs and caches its result.
    -- A hard cleanup bumps the generation to invalidate them all at once.
    ctx.request_generation = ctx.request_generation or 0
    local request_generation = ctx.request_generation

    -- First-line early paint. With a display cap active, the visible portion of
    -- a streamed completion is final as soon as the stream moves past it (~the
    -- first newline) -- several hundred ms before the full generation finishes
    -- (codestral, 64 tokens: first line ~575ms vs stream done ~955ms, see
    -- scripts/probe_codestral_first_line_stream.py). Paint it then instead of
    -- at request exit. The partial never enters the cache; when the request
    -- settles, the full completion replaces it seamlessly (same visible line,
    -- longer hidden tail). Uncapped triggers (e.g. a manual multi-line keymap)
    -- get no hook: their visible portion is only final at the end of the
    -- stream, which is the paint-on-exit behavior they already have.
    if ctx.display_max_lines then
        local display_max_lines = ctx.display_max_lines
        context.opts.on_stream_partial = function(text)
            if api.nvim_get_current_buf() ~= bufnr or ctx.request_generation ~= request_generation then
                return
            end
            -- Never paint over an existing view: cached suggestions already
            -- shown are complete and cyclable, and a distinct fetch holds the
            -- user's current view until its result lands.
            if ctx.distinct_active or (ctx.suggestions and #ctx.suggestions > 0) then
                return
            end
            text = truncate_at_stop_tokens(text, params.stop_tokens)
            -- The user may have typed while the stream is in flight.
            local remainder = live_remainder(cfg, cur_before, cur_after, text)
            -- Paint only once the visible portion is final, i.e. the stream has
            -- produced at least one display line beyond the cut.
            if not remainder or not display_cut(vim.split(remainder, '\n', { plain = true }), display_max_lines) then
                return
            end
            ctx.suggestions = { remainder }
            ctx.choice = 1
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
        end
    elseif extend then
        -- An extension only ever appends to the ghost text already on screen, so
        -- its partials are safe to paint the moment they arrive: each repaint is
        -- a strict superset of the last, which is the reveal growing rather than
        -- anything visible changing. The cyclable siblings come back when the
        -- request settles and the callback re-derives the pool.
        context.opts.on_stream_partial = function(text)
            if api.nvim_get_current_buf() ~= bufnr or ctx.request_generation ~= request_generation then
                return
            end
            if ctx.extend_active ~= extend then
                return
            end
            text = truncate_at_stop_tokens(text, params.stop_tokens)
            local remainder = live_remainder(cfg, cur_before, cur_after, extend .. text)
            if not remainder then
                return
            end
            ctx.suggestions = { remainder }
            ctx.choice = 1
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
        end
    end

    provider.complete(context, function(data, done)
        if api.nvim_get_current_buf() ~= bufnr then
            return
        end

        data = utils.list_dedup(data or {})

        -- An extend request generated the text *past* the ghost text, so stitch
        -- it back on: every completion in a cache slot starts at that slot's
        -- cursor, and this one is keyed at the real cursor like any other. An
        -- empty continuation stitches back to the seed, which carries no new
        -- text, so drop it here and let `next(data)` read as "nothing came back".
        if extend then
            local stitched = {}
            for _, c in ipairs(data) do
                if #c > 0 then
                    table.insert(stitched, extend .. c)
                end
            end
            data = stitched
        end

        local entry = cache_entry(ctx, params, cur_before, cur_after)
        local cache = ctx.cache

        -- Merge new completions into the entry (deduplicated)
        local existing = {}
        for _, c in ipairs(entry.completions) do existing[c] = true end
        for _, c in ipairs(data) do
            if not existing[c] then
                existing[c] = true
                table.insert(entry.completions, c)
            end
        end

        -- The seed the extend pinned was a placeholder for the text being
        -- generated. Once a real continuation of it lands it is a strict prefix
        -- of that one: nothing to cycle to, and it would pin the display short
        -- of the reveal it stood in for.
        if extend and #data > 0 then
            for i = #entry.completions, 1, -1 do
                if entry.completions[i] == extend then
                    table.remove(entry.completions, i)
                end
            end
        end

        local pool_size = cfg.virtualtext.pool_size or 8
        while #cache > pool_size do
            table.remove(cache, 1)
        end

        -- Caching above always runs so a request fired for an earlier keystroke
        -- still lands its completion. Painting and retrying, though, are display
        -- concerns: skip them once a hard cleanup (dismiss / insert-leave) has
        -- invalidated this request's generation.
        if ctx.request_generation ~= request_generation then
            return
        end

        -- Re-read cursor position so we don't flash stale ghost-text when the
        -- user typed ahead while the request was in flight.
        local cmp_ctx_now = utils.make_cmp_context()
        local ctx_now = vt_get_context(cmp_ctx_now, cfg)
        local effective, effective_choice, n_fresh_now = derive_suggestions(
            ctx,
            params,
            ctx_now.lines_before,
            ctx_now.lines_after,
            ctx_now.opts.is_incomplete_before,
            cfg
        )

        -- Extend: hold the revealed ghost text until its continuation lands, then
        -- grow into it. The picked completion starts with what is on screen, so
        -- the repaint only appends.
        if ctx.extend_active then
            if extend ~= ctx.extend_active then
                -- A result from another request of this family: cached above,
                -- but it must not repaint over the text being continued.
                return
            end
            local picked
            for i, comp in ipairs(effective) do
                if #comp > #extend and comp:sub(1, #extend) == extend then
                    picked = i
                    break
                end
            end
            if picked then
                ctx.extend_active = nil
                set_lock(
                    ctx,
                    params,
                    effective[picked],
                    ctx_now.lines_before,
                    ctx_now.lines_after,
                    ctx_now.opts.is_incomplete_before
                )
                -- Re-derive against the new lock: the seed it replaces is gone
                -- from the pool, so the list above still carries it as a pinned
                -- leftover -- a cyclable entry that is a strict prefix of what
                -- is now on screen.
                local grown, grown_choice = derive_suggestions(
                    ctx,
                    params,
                    ctx_now.lines_before,
                    ctx_now.lines_after,
                    ctx_now.opts.is_incomplete_before,
                    cfg
                )
                ctx.suggestions = grown
                ctx.choice = grown_choice
                ctx.shown_choices = ctx.shown_choices or {}
                update_preview(ctx)
            elseif done ~= false then
                -- Nothing continues the ghost text: either the model had nothing
                -- to add past it -- an empty continuation is a real answer here,
                -- unlike a repeated completion in a distinct fetch, so there is
                -- nothing to retry for -- or the cursor moved on. Either way the
                -- revealed text stays exactly as it is.
                ctx.extend_active = nil
                update_preview(ctx)
            end
            return
        end

        -- Distinct fetch (loud cycle-past-the-last, or a silent tail prefetch):
        -- keep the current view until a completion the user has not already seen
        -- lands. A loud fetch cycles to it; a silent one just appends it, keeping
        -- the user on their current entry so the next cycle has somewhere to go.
        if ctx.distinct_active then
            local picked
            for i, comp in ipairs(effective) do
                if not ctx.distinct_seen[visible_key(comp, ctx.display_max_lines)] then
                    picked = i
                    break
                end
            end
            if picked then
                local silent = ctx.distinct_silent
                local current = ctx.suggestions and ctx.choice and ctx.suggestions[ctx.choice]
                ctx.suggestions = effective
                ctx.shown_choices = ctx.shown_choices or {}
                ctx.distinct_active = nil
                ctx.distinct_silent = nil
                if silent then
                    ctx.choice = 1
                    for i, comp in ipairs(effective) do
                        if comp == current then
                            ctx.choice = i
                            break
                        end
                    end
                else
                    ctx.choice = picked
                    set_lock(
                        ctx,
                        params,
                        effective[picked],
                        ctx_now.lines_before,
                        ctx_now.lines_after,
                        ctx_now.opts.is_incomplete_before
                    )
                end
                update_preview(ctx)
            elseif done ~= false then
                ctx.distinct_attempts = (ctx.distinct_attempts or 0) + 1
                if next(data) and ctx.distinct_attempts < max_retries then
                    trigger(bufnr, overrides, true)
                else
                    -- Gave up: drop the dots (if any), leave the user where they are.
                    ctx.distinct_active = nil
                    ctx.distinct_silent = nil
                    update_preview(ctx)
                end
            end
            return
        end

        if #effective > 0 then
            ctx.suggestions = effective
            ctx.choice = effective_choice
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
        end

        -- Keep retrying until the state holds n_completions *fresh* completions
        -- or the per-state budget runs out (the "move on" case). Soft / hard
        -- entries are shown but do not count, so a position that only yields one
        -- distinct completion stops after max_retries instead of looping.
        if done ~= false then
            local n_retries = ctx.n_retries or 0
            if next(data)
                and n_fresh_now < n_completions
                and n_retries < max_retries
            then
                ctx.n_retries = n_retries + 1
                trigger(bufnr, overrides, true)
            end
        end
    end, cfg)
end

--- Fetch a completion the user has not seen yet at the current state. Two modes:
---   * loud (default): the user asked for it (cycled off the end). Show loading
---     dots and cycle to the new completion when it lands.
---   * silent: a preemptive prefetch fired while cycling near the tail. No dots;
---     when a distinct completion lands, append it to the list but keep the user
---     on their current entry, so the next cycle has somewhere to go without a
---     wait.
--- Either way it snapshots the seen set and fires requests (bypassing the bucket
--- gates) until a not-yet-seen completion lands or the attempt budget runs out --
--- never wrapping back to the first suggestion or to an empty display.
---@param ctx minuet.VirtualtextSuggestionContext
---@param overrides? table
---@param silent? boolean preemptive prefetch: no dots, do not cycle
local function start_distinct_fetch(ctx, overrides, silent)
    if ctx.distinct_active then
        -- A silent prefetch is already running; an explicit (loud) request
        -- upgrades it so the user gets dots now and is cycled when it lands.
        if not silent and ctx.distinct_silent then
            ctx.distinct_silent = nil
            update_preview(ctx)
        end
        return
    end
    -- Seen-ness is judged on the rendered portion, like the pool: a fetch that
    -- only differs past the display cut would paint the exact same ghost text,
    -- so it must not count as the distinct completion the user asked for.
    ctx.distinct_seen = {}
    for _, s in ipairs(ctx.suggestions or {}) do
        ctx.distinct_seen[visible_key(s, ctx.display_max_lines)] = true
    end
    ctx.distinct_active = true
    ctx.distinct_silent = silent or nil
    ctx.distinct_attempts = 0
    if not silent then
        update_preview(ctx)
    end
    trigger(api.nvim_get_current_buf(), overrides, false, true)
end

---@param count integer
---@param ctx minuet.VirtualtextSuggestionContext
---@param overrides? table param patch for a preemptive tail prefetch
local function advance(count, ctx, overrides)
    if ctx ~= get_ctx() then
        return
    end

    ctx.choice = (ctx.choice + count) % #ctx.suggestions
    if ctx.choice < 1 then
        ctx.choice = #ctx.suggestions
    end

    -- Cycling re-locks this buffer state to the chosen completion: returning to
    -- the state re-shows it (over the natural most-context ranking) until the
    -- user cycles again or dismisses.
    local chosen = ctx.suggestions[ctx.choice]
    if chosen and ctx.cur_before and ctx.last_trigger_params then
        set_lock(ctx, ctx.last_trigger_params, chosen, ctx.cur_before, ctx.cur_after, ctx.cur_incomplete_before)
    end

    update_preview(ctx)

    -- Preemptive tail prefetch: when cycling lands within prefetch_ahead entries
    -- of the end, fetch a distinct completion in the background so scrolling
    -- further never blocks on a request.
    local prefetch_ahead = (require('minuet').config.virtualtext or {}).prefetch_ahead or 0
    if prefetch_ahead > 0 and count > 0 and ctx.choice > #ctx.suggestions - prefetch_ahead then
        start_distinct_fetch(ctx, overrides, true)
    end
end

--- Fire an auto-trigger request through the debounce/throttle/predicate gates.
---@param overrides? table Config patch for the request. Top-ups fired on behalf
---of what is on screen pass `ctx.last_trigger_overrides` so they stay in the
---displayed family instead of reverting to the default one.
local function schedule(overrides)
    if internal.is_on_throttle then
        return
    end

    stop_timer()

    local config = require('minuet').config
    local bufnr = api.nvim_get_current_buf()

    local function maybe_trigger()
        local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

        if
            internal.is_on_throttle
            or (not show_on_completion_menu and completion_menu_visible())
            or (not utils.run_hooks_until_failure(config.enable_predicates))
            -- Re-check at fire time: in 'unintrusive' mode the cursor may have
            -- moved into a position with non-whitespace text after it during
            -- the debounce window.
            or (not should_auto_trigger())
        then
            return
        end

        if (config.throttle or 0) > 0 then
            internal.is_on_throttle = true
            vim.defer_fn(function()
                internal.is_on_throttle = false
            end, config.throttle)
        end

        trigger(bufnr, overrides)
    end

    if (config.debounce or 0) <= 0 then
        maybe_trigger()
        return
    end

    internal.timer = vim.defer_fn(maybe_trigger, config.debounce)
end

local action = {}

---@param overrides? table Partial config patch, deep-merged onto the live
---config for this single request only. No global mutation. Useful for
---one-off completions with a different provider/model/stop tokens.
---Bypasses auto-trigger gating (debounce/throttle/predicates).
function action.fire(overrides)
    trigger(api.nvim_get_current_buf(), overrides, false, true)
end

---@param overrides? table Optional config patch.
---Behavior:
---  * no suggestions yet → fire a trigger with overrides applied
---  * suggestions visible but this press asks for a DIFFERENT param-set than
---    the one that produced them (e.g. autotrigger results with stop=\n are
---    showing and the user presses a keymap that overrides stop=\n\n -- or the
---    plain keymap while a manual family is showing) → fire a fresh trigger so
---    the user gets the family they asked for instead of cycling inside the
---    other one. With `virtualtext.extend_visible` set for the family being
---    asked for, that trigger continues the visible ghost text rather than
---    replacing it.
---  * cycling forward off the end of the list → fetch a new, distinct completion
---    (loading dots) instead of wrapping back to the first
---  * otherwise → cycle within the visible set
local function cycle_or_fetch(direction, overrides)
    local ctx = get_ctx()

    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf(), overrides, false, true)
        return
    end

    -- Resolve the family this press asks for with or without overrides: the
    -- plain keymap asks for the default family just as explicitly as an
    -- overriding one asks for its own, so it must switch back when another
    -- family is on screen rather than cycling within it.
    local cfg = require('minuet').config
    if overrides then
        cfg = vim.tbl_deep_extend('force', cfg, overrides)
    end
    if not vim.deep_equal(extract_cache_params(cfg), ctx.last_trigger_params) then
        local shown = (cfg.virtualtext or {}).extend_visible and get_current_suggestion(ctx) or nil
        trigger(api.nvim_get_current_buf(), overrides, false, true, shown ~= '' and shown or nil)
        return
    end

    if direction > 0 and ctx.choice and ctx.choice >= #ctx.suggestions then
        start_distinct_fetch(ctx, overrides)
        return
    end

    advance(direction, ctx, overrides)
end

action.next = function(overrides)
    cycle_or_fetch(1, overrides)
end

action.prev = function(overrides)
    cycle_or_fetch(-1, overrides)
end

-- Slide cache entries forward by `accepted` so they remain the canonical match
-- for the new cursor position. For each entry, keep only completions that begin
-- with `accepted` (those came from the same suggestion family the user just
-- partially accepted), strip the accepted prefix off them, extend the entry's
-- lines_before, and stamp the current changedtick so the typed_since==0 stale
-- guard in pool_suggestions does not skip the entry on the next CursorMovedI.
-- This is what keeps the cache priority #1 across long accept-word sessions:
-- the hard drift limit never trips because the entries follow the cursor.
local function slide_cache_after_accept(ctx, accepted)
    if not ctx.cache or #accepted == 0 then
        return
    end
    local changedtick = api.nvim_buf_get_changedtick(0)
    for _, entry in ipairs(ctx.cache) do
        local kept = {}
        for _, comp in ipairs(entry.completions) do
            if comp:sub(1, #accepted) == accepted then
                table.insert(kept, comp:sub(#accepted + 1))
            end
        end
        if #kept > 0 then
            entry.lines_before = entry.lines_before .. accepted
            entry.completions = kept
            entry.changedtick = changedtick
            -- The slide keeps the entry displayable, but its completions were
            -- generated from the pre-accept context; the accumulated slide
            -- counts as freshness drift in pool_suggestions.
            entry.slid_chars = (entry.slid_chars or 0) + #accepted
        end
    end
end

-- Slide the per-state locks forward by `accepted`, the lock-ring analogue of
-- slide_cache_after_accept. The completion the user just partially accepted is
-- re-anchored at the new (post-accept) state with the accepted head stripped,
-- so its remainder stays priority #1 -- re-shown over the natural ranking as
-- background top-ups land or the user types on into it -- instead of being left
-- behind at the pre-accept state, where the windowed prefix eventually slides
-- past lines_before and compatible_lock stops matching (the mid-accept rug
-- pull). lines_after is untouched (an insert at the cursor leaves the suffix).
-- Same forward-anchoring trick as the cache slide: a growing lines_before stays
-- matchable via the incomplete-before branch of prefix_typed_since. Locks for a
-- different family, or fully consumed by this accept, are left as-is.
local function slide_locks_after_accept(ctx, accepted)
    if not ctx.locks or #accepted == 0 then
        return
    end
    for _, lock in ipairs(ctx.locks) do
        if #lock.completion > #accepted and lock.completion:sub(1, #accepted) == accepted then
            lock.completion = lock.completion:sub(#accepted + 1)
            lock.lines_before = lock.lines_before .. accepted
        end
    end
end

-- Slice ctx.suggestions forward by `accepted`, preserving the index of the
-- active suggestion so cycling continues from the same spot. Siblings that
-- don't start with `accepted` are dropped — they belong to a different family
-- than the one the user just committed to.
local function slice_suggestions_after_accept(ctx, accepted)
    if not ctx.suggestions or #ctx.suggestions == 0 then
        return
    end
    local active_idx = ctx.choice or 1
    local kept = {}
    local new_choice
    for i, s in ipairs(ctx.suggestions) do
        if s:sub(1, #accepted) == accepted then
            local rest = s:sub(#accepted + 1)
            if #rest > 0 then
                table.insert(kept, rest)
                if i == active_idx then
                    new_choice = #kept
                end
            end
        end
    end
    if #kept == 0 then
        reset_ctx(ctx)
        return
    end
    ctx.suggestions = kept
    ctx.choice = new_choice or 1
end

-- Insert the first n_chars of the current suggestion. Runs synchronously when
-- no popup is open so that an auto-repeated keymap can immediately read the
-- sliced remainder on the next press, instead of seeing the unsliced
-- suggestion and re-inserting its first word. While the edit is in flight
-- `ctx.in_accept` is set so the synchronously fired CursorMovedI short-circuits
-- in on_cursor_moved_i and does not race with the slice. The cache is slid
-- forward by `to_insert` so future CursorMovedI events keep the same entry as
-- the canonical match (no flash, no drift expiration).
local function accept_n_chars(n_chars)
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    if not suggestion or #suggestion == 0 then
        return
    end

    local to_insert = n_chars and suggestion:sub(1, n_chars) or suggestion
    local has_remaining = n_chars ~= nil and #suggestion > n_chars

    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]
    local lines = vim.split(to_insert, '\n', { plain = true })

    local function apply()
        ctx.in_accept = true
        stop_timer()
        -- Do not terminate in-flight jobs here. Let them populate ctx.cache, but
        -- prevent their callbacks from repainting the sliced partial-accept view.
        bump_request_generation(ctx)
        -- Those callbacks are also the ones that would clear these, so an accept
        -- has to: a pending fetch left marked active would keep its loading dots
        -- painted and hold off the next paint for good.
        ctx.distinct_active = nil
        ctx.distinct_silent = nil
        ctx.extend_active = nil
        clear_preview()
        api.nvim_buf_set_text(0, line, col, line, col, lines)
        local new_col = #lines[#lines]
        if #lines == 1 then
            new_col = new_col + col
        end
        api.nvim_win_set_cursor(0, { line + #lines, new_col })
        slide_cache_after_accept(ctx, to_insert)
        if has_remaining then
            slide_locks_after_accept(ctx, to_insert)
            slice_suggestions_after_accept(ctx, to_insert)
            if ctx.cur_before then
                ctx.cur_before = ctx.cur_before .. to_insert
            end
            update_preview(ctx)
            -- An accept advances the cursor without a usable CursorMovedI (the
            -- post-accept event is suppressed), so the top-up must kick from
            -- here: accepting a line typically slides the pool past the soft
            -- band, where fuller-context completions are worth fetching before
            -- the user consumes the rest. trigger() applies the per-state
            -- budget, so this is a no-op while the state is still satisfied.
            -- Stay in the family being walked: a top-up fired as the default one
            -- would repaint the remainder with its results, under its display
            -- cap -- the rug pull that made accepting part of a manual
            -- multi-line completion drop or reshape the rest of it.
            if should_auto_trigger() then
                schedule(ctx.last_trigger_overrides)
            end
        else
            -- Fully consuming a suggestion frees its lock (derive_suggestions
            -- ignores the now-empty remainder and re-locks to the next result),
            -- so this is the one moment the "never change visible ghost text"
            -- rule does not apply: nothing is visible. Reconsider the cache and
            -- paint the next compatible completion here, synchronously in the
            -- same event as the accept edit -- the post-accept CursorMovedI is
            -- suppressed by skip_cursor_moved_after_accept, so without this the
            -- follow-up ghost text would wait for the next keystroke.
            reset_ctx(ctx)
            local cfg = require('minuet').config
            if ctx.last_trigger_params and (should_auto_trigger() or ctx.last_trigger_was_manual) then
                local context = vt_get_context(utils.make_cmp_context(), cfg)
                local effective, choice, n_fresh = derive_suggestions(
                    ctx,
                    ctx.last_trigger_params,
                    context.lines_before,
                    context.lines_after,
                    context.opts.is_incomplete_before,
                    cfg
                )
                if #effective > 0 then
                    ctx.suggestions = effective
                    ctx.choice = choice
                    ctx.shown_choices = ctx.shown_choices or {}
                    update_preview(ctx)
                end
                -- Same top-up rule as on_cursor_moved_i: short of fresh
                -- completions at the new state, kick a background fetch -- in
                -- the family whose cache was just re-derived.
                if n_fresh < (cfg.n_completions or 3) and should_auto_trigger() then
                    schedule(ctx.last_trigger_overrides)
                end
            end
        end
        ctx.skip_cursor_moved_after_accept = {
            row = line + #lines,
            col = new_col,
            changedtick = api.nvim_buf_get_changedtick(0),
        }
        ctx.in_accept = nil
    end

    if vim.fn.pumvisible() == 1 then
        -- Accepting Minuet completion while the pum is open is temporary; when
        -- the user closes the pum, Vim restores the buffer state and removes
        -- Minuet's completion text. Close the pum first via feedkeys, then run
        -- the edit on the next tick so the C-e is processed before our edit.
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
        vim.schedule(apply)
    else
        apply()
    end
end

-- Returns the byte length of the next "word unit" in s, matching :h word /
-- the `e` normal-mode motion: leading blanks (including EOL) followed by
-- either a run of \k chars or a run of non-blank non-\k chars. Returns nil
-- when s is empty or contains no word.
--
-- \_s is vim's whitespace-or-EOL class; \k\@!\S is "non-blank that is not a
-- keyword char", so the second alternative groups runs of punctuation the way
-- `e` does (e.g. `foo!!!bar` -> foo, !!!, bar). \k and \S handle multibyte
-- input on their own, so no per-character walk is needed.
local function next_word_end(s)
    if #s == 0 then
        return nil
    end
    local byte_end = vim.fn.matchend(s, [[^\_s*\(\k\+\|\%(\k\@!\S\)\+\)]])
    if byte_end < 0 then
        return nil
    end
    return byte_end
end

-- Returns the byte index of the end of the nth word unit in s.
local function find_nth_word_end(s, n)
    local pos = 0
    for _ = 1, n do
        local len = next_word_end(s:sub(pos + 1))
        if not len then
            return nil
        end
        pos = pos + len
    end
    return pos
end

---@param n_lines? integer Number of lines to accept. If both params are nil,
---accepts everything shown: the whole suggestion, or just the visible portion
---when a display cap is hiding tail lines (what you see is what you accept --
---the remainder stays the active suggestion, so repeated accepts walk the
---completion line by line).
---@param n_words? integer Number of word units to accept. Takes precedence over n_lines.
---Accepts the current suggestion by inserting it at the cursor position.
---After insertion, moves the cursor to the end of the inserted text.
function action.accept(n_lines, n_words)
    local ctx = get_ctx()

    local suggestion = get_current_suggestion(ctx)
    if not suggestion then
        return
    end

    if n_words then
        local n = find_nth_word_end(suggestion, n_words)
        if not n then
            return
        end
        accept_n_chars(n)
        return
    end

    if n_lines then
        local lines = vim.split(suggestion, '\n', { plain = true })
        -- An empty leading element means the original suggestion began with a
        -- newline (typical after a partial accept). The user wants the next
        -- visible line, so bump n_lines past that empty.
        if lines[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #lines)
        local picked = vim.list_slice(lines, 1, n_lines)
        accept_n_chars(#table.concat(picked, '\n'))
        return
    end

    local lines = vim.split(suggestion, '\n', { plain = true })
    local cut = display_cut(lines, ctx.display_max_lines)
    if cut then
        accept_n_chars(#table.concat(vim.list_slice(lines, 1, cut), '\n'))
        return
    end

    accept_n_chars(#suggestion)
end

function action.accept_word()
    action.accept(nil, 1)
end

-- Like vim's f{char}: accept the suggestion up to and including the next
-- occurrence of the prompted character.
function action.accept_until_char()
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    if not suggestion or #suggestion == 0 then
        return
    end

    local char = vim.fn.getcharstr()
    if not char or char == '' then
        return
    end

    local _, end_idx = suggestion:find(char, 1, true)
    if not end_idx then
        return
    end

    accept_n_chars(end_idx)
end

function action.accept_n_lines()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local n = vim.fn.input 'accept n lines: '

    -- FIXME: vim.fn.input may change cursor position, we need to restore the
    -- cursor position after the user input.

    vim.api.nvim_win_set_cursor(0, cursor_pos)

    ---@diagnostic disable-next-line:cast-local-type
    n = tonumber(n)
    if not n then
        return
    end
    if n > 0 then
        action.accept(n)
    else
        vim.notify('Invalid number of lines', vim.log.levels.ERROR)
    end
end

function action.accept_line()
    action.accept(1)
end

function action.dismiss()
    local ctx = get_ctx()
    -- By default an explicit dismiss also drops the state locks (a clean reset).
    -- With dismiss_drops_lock = false the user treats dismiss as a temporary
    -- "get out of my way" hide, so the locks survive and re-triggering at a
    -- locked state brings the chosen completion back.
    if (require('minuet').config.virtualtext or {}).dismiss_drops_lock ~= false then
        ctx.locks = nil
    end
    cleanup(ctx)
end

function action.is_visible()
    return not not api.nvim_buf_get_extmark_by_id(0, internal.ns_id, internal.extmark_id, { details = false })[1]
end

---@param mode 'off' | 'unintrusive' | 'full'
function action.set_auto_trigger_mode(mode)
    if mode ~= 'off' and mode ~= 'unintrusive' and mode ~= 'full' then
        vim.notify(
            'Minuet Virtual Text auto trigger mode must be one of: off, unintrusive, full',
            vim.log.levels.ERROR
        )
        return
    end
    vim.b.minuet_virtual_text_auto_trigger_mode = mode
    -- Reflect the new mode on the display side: if the new state allows
    -- auto-triggering at the current cursor position, fire a request right
    -- away so the user does not have to type a character to see a completion.
    -- Otherwise clear any currently visible ghost text so disabling /
    -- switching to unintrusive over occupied text actually dismisses it.
    if should_auto_trigger() then
        trigger(api.nvim_get_current_buf(), nil, false, false)
    else
        cleanup(get_ctx())
    end
    vim.notify('Minuet Virtual Text auto trigger: ' .. mode, vim.log.levels.INFO)
end

function action.disable_auto_trigger()
    action.set_auto_trigger_mode 'off'
end

-- Restore the mode configured in `config.virtualtext.auto_trigger_mode`.
-- If the configured value is itself 'off', default to 'full' so a user who
-- presses "enable" actually gets auto-triggering.
function action.enable_auto_trigger()
    local configured = require('minuet').config.virtualtext.auto_trigger_mode or 'full'
    if configured == 'off' then
        configured = 'full'
    end
    action.set_auto_trigger_mode(configured)
end

function action.toggle_auto_trigger()
    if auto_trigger_mode() == 'off' then
        action.enable_auto_trigger()
    else
        action.disable_auto_trigger()
    end
end

M.action = action

local autocmd = {}

function autocmd.on_insert_leave()
    cleanup()
end

function autocmd.on_buf_leave()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_leave()
    end
end

function autocmd.on_insert_enter()
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_enter()
    end
end

function autocmd.on_cursor_moved_i()
    local bufnr = api.nvim_get_current_buf()
    local ctx = get_ctx(bufnr)

    -- accept_n_chars sets this around its synchronous buffer edit + cursor
    -- move. The CursorMovedI fired by our own edit must not re-derive from the
    -- cache: accept_n_chars has already sliced ctx.suggestions and slid the
    -- cache forward, so running pool_suggestions here would just race with
    -- that and could repaint with stale state.
    if ctx.in_accept then
        return
    end

    -- In real insert mode the CursorMovedI caused by nvim_win_set_cursor can be
    -- delivered after accept_n_chars has already sliced and repainted the
    -- remainder. Do not immediately re-derive from sibling cache entries for that
    -- same post-accept cursor state; the next genuine cursor move/edit should use
    -- the normal cache path below.
    local skip = ctx.skip_cursor_moved_after_accept
    if skip then
        ctx.skip_cursor_moved_after_accept = nil
        local cursor = api.nvim_win_get_cursor(0)
        if
            cursor[1] == skip.row
            and cursor[2] == skip.col
            and api.nvim_buf_get_changedtick(bufnr) == skip.changedtick
        then
            return
        end
    end

    -- Moving the cursor abandons any in-flight cycle-past-the-last fetch or
    -- pending extension: the state each was fetching for is no longer current,
    -- so drop the dots and let the normal re-derive below take over.
    ctx.distinct_active = nil
    ctx.extend_active = nil

    -- Only serve cached completions when auto-trigger is on, or when the user
    -- explicitly fired a manual completion that is still "live" (not yet
    -- dismissed by cleanup). This prevents stale ghost-text from appearing
    -- while the user has auto-trigger deliberately turned off.
    local can_show_cache = should_auto_trigger() or ctx.last_trigger_was_manual

    -- Check cache with the params from the last trigger. Using stored params
    -- (rather than re-resolving the config) means one-off completions fired
    -- with overridden model/stop-tokens keep working while the user types into
    -- them, without contaminating or being contaminated by the default cache.
    if can_show_cache and ctx.last_trigger_params then
        local cfg = require('minuet').config
        local context = resolve_context(utils.make_cmp_context(), cfg, ctx, ctx.last_trigger_params)
        local effective, choice, n_fresh = derive_suggestions(
            ctx,
            ctx.last_trigger_params,
            context.lines_before,
            context.lines_after,
            context.opts.is_incomplete_before,
            cfg
        )
        if #effective > 0 then
            ctx.suggestions = effective
            ctx.choice = choice
            ctx.shown_choices = ctx.shown_choices or {}
            update_preview(ctx)
            -- Soft invalidation: keep the cached suggestions on screen but, if we
            -- are short of n_completions fresh ones, kick a background top-up in
            -- the family that is showing (the same one we just derived from).
            -- trigger() applies the per-state budget, so this stops re-firing
            -- once the state has been exhausted ("move on").
            if n_fresh < (cfg.n_completions or 3) and should_auto_trigger() then
                schedule(ctx.last_trigger_overrides)
            else
                stop_timer()
            end
            return
        end
    end

    -- Cache miss: clear display state if something was shown, then request fresh.
    -- soft=true preserves ctx.last_trigger_was_manual so a backspace that
    -- realigns the cursor with a cached prefix can revive the suggestion (the
    -- typo+backspace recovery path for manual-trigger users).
    if ctx.shown_choices and next(ctx.shown_choices) then
        cleanup(ctx, true)
    end
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_cursor_hold_i()
    update_preview()
end

function autocmd.on_text_changed_p()
    autocmd.on_cursor_moved_i()
end

---@param info { buf: integer }
function autocmd.on_buf_unload(info)
    internal.context[info.buf] = nil
end

local function create_autocmds()
    api.nvim_create_autocmd('InsertLeave', {
        group = internal.augroup,
        callback = autocmd.on_insert_leave,
        desc = '[minuet.virtualtext] insert leave',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = internal.augroup,
        callback = autocmd.on_buf_leave,
        desc = '[minuet.virtualtext] buf leave',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = internal.augroup,
        callback = autocmd.on_insert_enter,
        desc = '[minuet.virtualtext] insert enter',
    })

    api.nvim_create_autocmd('BufEnter', {
        group = internal.augroup,
        callback = autocmd.on_buf_enter,
        desc = '[minuet.virtualtext] buf enter',
    })

    api.nvim_create_autocmd('CursorMovedI', {
        group = internal.augroup,
        callback = autocmd.on_cursor_moved_i,
        desc = '[minuet.virtualtext] cursor moved insert',
    })

    api.nvim_create_autocmd('TextChangedP', {
        group = internal.augroup,
        callback = autocmd.on_text_changed_p,
        desc = '[minuet.virtualtext] text changed p',
    })

    api.nvim_create_autocmd('BufUnload', {
        group = internal.augroup,
        callback = autocmd.on_buf_unload,
        desc = '[minuet.virtualtext] buf unload',
    })
end

local function set_keymaps(keymap)
    if keymap.accept then
        vim.keymap.set('i', keymap.accept, action.accept, {
            desc = '[minuet.virtualtext] accept suggestion',
            silent = true,
        })
    end

    if keymap.accept_line then
        vim.keymap.set('i', keymap.accept_line, action.accept_line, {
            desc = '[minuet.virtualtext] accept suggestion (line)',
            silent = true,
        })
    end

    if keymap.accept_n_lines then
        vim.keymap.set('i', keymap.accept_n_lines, action.accept_n_lines, {
            desc = '[minuet.virtualtext] accept suggestion (n lines)',
            silent = true,
        })
    end

    if keymap.accept_word then
        vim.keymap.set('i', keymap.accept_word, action.accept_word, {
            desc = '[minuet.virtualtext] accept next word',
            silent = true,
        })
    end

    if keymap.accept_until_char then
        vim.keymap.set('i', keymap.accept_until_char, action.accept_until_char, {
            desc = '[minuet.virtualtext] accept until char (f-like)',
            silent = true,
        })
    end

    if keymap.next then
        vim.keymap.set('i', keymap.next, action.next, {
            desc = '[minuet.virtualtext] next suggestion',
            silent = true,
        })
    end

    if keymap.prev then
        vim.keymap.set('i', keymap.prev, action.prev, {
            desc = '[minuet.virtualtext] prev suggestion',
            silent = true,
        })
    end

    if keymap.dismiss then
        vim.keymap.set('i', keymap.dismiss, action.dismiss, {
            desc = '[minuet.virtualtext] dismiss suggestion',
            silent = true,
        })
    end
end

function M.setup()
    local config = require('minuet').config
    api.nvim_clear_autocmds { group = M.augroup }

    if #config.virtualtext.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.virtualtext.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.virtualtext.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.minuet_virtual_text_auto_trigger_mode = config.virtualtext.auto_trigger_mode or 'full'
                end
            end,
            group = M.augroup,
            desc = 'minuet virtual text filetype auto trigger',
        })
    end

    create_autocmds()
    set_keymaps(config.virtualtext.keymap)
end

return M
