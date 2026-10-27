-- Duet NES session: local edit-history tracking (no undotree) and the
-- KV-cache-aware message assembly for a long-lived "code session".
--
-- Edits are captured as a bounded, append-only sequence and rendered in
-- apply_patch dialect WITH expanded context, so the model tracks real buffer
-- state. See duet-nes-spec.md.

local nes = require 'minuet.duet.nes_context'

local M = {}

local function get_diff(a, b, ctxlen)
    local diff = (vim.text and vim.text.diff) or vim.diff
    return diff(a, b, {
        result_type = 'unified',
        algorithm = 'histogram',
        ctxlen = ctxlen,
    })
end

local function clean_diff_lines(unified)
    local lines = vim.split(unified, '\n', { plain = true })
    if lines[#lines] == '' then
        table.remove(lines)
    end
    local out = {}
    for _, line in ipairs(lines) do
        if line:sub(1, 1) == '\\' then
            -- drop git's "\ No newline at end of file" marker
        else
            table.insert(out, line)
        end
    end
    return out
end

--- Render a single edit (before -> after) as an apply_patch update block with
--- `ctx_lines` of surrounding context. Reuses nvim's diff and rewrites the
--- `@@ -a,b +c,d @@` headers into bare `@@` (apply_patch dialect). Returns nil
--- when there is no change.
---@param before string[]
---@param after string[]
---@param path string
---@param ctx_lines? integer
---@return string?
function M.render_edit(before, after, path, ctx_lines)
    ctx_lines = ctx_lines or 8
    local a = table.concat(before, '\n')
    local b = table.concat(after, '\n')
    if a == b then
        return nil
    end

    local unified = get_diff(a, b, ctx_lines)
    if not unified or unified == '' then
        return nil
    end

    local out = { '*** Begin Patch', '*** Update File: ' .. path }
    for _, line in ipairs(clean_diff_lines(unified)) do
        if line:sub(1, 2) == '@@' then
            table.insert(out, '@@')
        else
            table.insert(out, line)
        end
    end
    table.insert(out, '*** End Patch')
    return table.concat(out, '\n')
end

--- Extract the single bounding changed region between two line arrays as the
--- before/after blocks of one edit. Spans across hunks (so several edits in the
--- same area read as one block before -> block after), matching the range-based
--- representation Mercury Edit's `edit_diff_history` was trained on. Returns nil
--- when nothing changed.
---@param before string[]
---@param after string[]
---@return string[]? original, string[]? updated, integer? start_line
function M.diff_region(before, after)
    local a = table.concat(before, '\n')
    local b = table.concat(after, '\n')
    if a == b then
        return nil
    end
    local hunks = vim.diff(a, b, { result_type = 'indices', algorithm = 'histogram' })
    if not hunks or #hunks == 0 then
        return nil
    end
    local a_lo, a_hi, b_lo, b_hi
    for _, h in ipairs(hunks) do
        local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
        if ca > 0 then
            a_lo = a_lo or sa
            a_hi = sa + ca - 1
        end
        if cb > 0 then
            b_lo = b_lo or sb
            b_hi = sb + cb - 1
        end
    end
    local original = a_lo and vim.list_slice(before, a_lo, a_hi) or {}
    local updated = b_lo and vim.list_slice(after, b_lo, b_hi) or {}
    return original, updated, (b_lo or a_lo or 1)
end

local function count_nonempty(lines)
    local n = 0
    for _, l in ipairs(lines) do
        if l ~= '' then
            n = n + 1
        end
    end
    return n
end

--- Render one edit-history entry in Mercury Edit's `edit_diff_history` dialect:
--- per-entry `--- / +++` headers, a synthetic `@@ -1,N +1,M @@` hunk (N/M count
--- the non-empty lines), then every non-empty original line as `-` and every
--- non-empty updated line as `+`. Blank lines are dropped, exactly as the
--- reference implementation does. `original`/`updated` are newline-joined blocks.
---@param entry { original: string, updated: string }
---@param path string
---@return string
function M.render_diff_entry(entry, path)
    local original = vim.split(entry.original, '\n', { plain = true })
    local updated = vim.split(entry.updated, '\n', { plain = true })
    local out = {
        '--- ' .. path,
        '+++ ' .. path,
        ('@@ -1,%d +1,%d @@'):format(count_nonempty(original), count_nonempty(updated)),
    }
    for _, l in ipairs(original) do
        if l ~= '' then
            out[#out + 1] = '-' .. l
        end
    end
    for _, l in ipairs(updated) do
        if l ~= '' then
            out[#out + 1] = '+' .. l
        end
    end
    return table.concat(out, '\n')
end

--- Render one edit-history entry as a FAITHFUL unified diff: real `--- / +++`
--- headers and a real `@@ -a,b +c,d @@` hunk with surrounding context, straight
--- from nvim's unified diff (blanks and positions preserved). This is the
--- 'unified' edit_history_format — in-distribution for diff-trained models, so
--- the model reads a removed line as a completed deletion instead of re-inserting
--- it. Returns nil when nothing changed.
---@param before string[]
---@param after string[]
---@param path string
---@param ctx_lines? integer
---@return string?
function M.render_diff_entry_unified(before, after, path, ctx_lines)
    ctx_lines = ctx_lines or 8
    local a = table.concat(before, '\n')
    local b = table.concat(after, '\n')
    if a == b then
        return nil
    end
    local unified = get_diff(a, b, ctx_lines)
    if not unified or unified == '' then
        return nil
    end
    -- nvim's unified diff starts at the `@@` hunk (git adds the file headers);
    -- prepend them so the block matches the edit_diff_history dialect.
    local out = { '--- ' .. path, '+++ ' .. path }
    for _, line in ipairs(clean_diff_lines(unified)) do
        out[#out + 1] = line
    end
    return table.concat(out, '\n')
end

--- Render a single before -> after edit straight to the `edit_diff_history`
--- block (convenience over diff_region + render_diff_entry). Returns nil when
--- nothing changed.
---@param before string[]
---@param after string[]
---@param path string
---@return string?
function M.render_edit_diff(before, after, path)
    local original, updated = M.diff_region(before, after)
    if not original then
        return nil
    end
    return M.render_diff_entry({ original = table.concat(original, '\n'), updated = table.concat(updated, '\n') }, path)
end

-- ---------------------------------------------------------------------------
-- Per-buffer edit tracker
-- ---------------------------------------------------------------------------

M.states = {}
M.diagnostic_history = {}

local function buf_path(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == '' then
        return '[No Name]'
    end
    return vim.fn.fnamemodify(name, ':.')
end

local function get_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param bufnr integer
---@return table state
function M.get_state(bufnr)
    local state = M.states[bufnr]
    if not state then
        state = {
            baseline = get_lines(bufnr),
            edits = {},
            diff_entries = {},
            seed = {},
            seed_diff_entries = {},
            started_ms = vim.uv.now(),
            last_ms = vim.uv.now(),
        }
        M.states[bufnr] = state
    end
    state.diff_entries = state.diff_entries or {}
    state.seed_diff_entries = state.seed_diff_entries or {}
    return state
end

local DEFAULT_EDIT_HISTORY_MAX_ENTRIES = 20

---@return table
local function session_config()
    local ok, minuet = pcall(require, 'minuet')
    return (ok and minuet.config and minuet.config.duet and minuet.config.duet.session) or {}
end

---@param state table
local function trim_diff_entries(state)
    local max_entries = tonumber(session_config().edit_history_max_entries) or DEFAULT_EDIT_HISTORY_MAX_ENTRIES
    if max_entries <= 0 then
        state.diff_entries = {}
        return
    end
    while #state.diff_entries > max_entries do
        table.remove(state.diff_entries, 1)
    end
end

--- Append one observed transition to both edit-history forms. This is used for
--- user edits and accepted model predictions, so the model sees the sequence of
--- buffer transitions it is actually participating in.
---@param state table
---@param before string[]
---@param after string[]
---@param path string
---@param ctx_lines? integer
---@return string?
local function append_transition(state, before, after, path, ctx_lines)
    local block = M.render_edit(before, after, path, ctx_lines)
    if not block then
        return nil
    end

    table.insert(state.edits, block)

    local original, updated, start_line = M.diff_region(before, after)
    if original then
        table.insert(state.diff_entries, {
            original = table.concat(original, '\n'),
            updated = table.concat(updated, '\n'),
            -- Precompute the faithful unified diff while we still hold the full
            -- before/after; the entry only keeps the changed region otherwise, so
            -- the 'unified' edit_history_format reads this back at render time.
            unified = M.render_diff_entry_unified(before, after, path, ctx_lines),
            start_line = start_line,
            ts_ms = vim.uv.now(),
        })
        trim_diff_entries(state)
    end

    return block
end

--- Re-snapshot the baseline (call on attach or after a prediction is applied so
--- the next captured edit is measured from the new state).
function M.rebase(bufnr)
    local state = M.get_state(bufnr)
    state.baseline = get_lines(bufnr)
end

--- Capture one edit: diff the current buffer against the stored baseline, record
--- it (uncoalesced), and advance the baseline. Returns the rendered block, if any.
---@param bufnr integer
---@param ctx_lines? integer
---@return string?
function M.capture(bufnr, ctx_lines)
    local state = M.get_state(bufnr)
    local cur = get_lines(bufnr)
    local block = append_transition(state, state.baseline, cur, buf_path(bufnr), ctx_lines)
    if block then
        state.baseline = cur
        state.last_ms = vim.uv.now()
    end
    return block
end

--- Record a model prediction the user accepted. Neovim does not emit TextChanged
--- for our own buffer write, but the accepted edit is still part of the real edit
--- trajectory Mercury should see on the next request.
---@param bufnr integer
---@param before string[]
---@param after string[]
---@param ctx_lines? integer
---@return string?
function M.record_accepted_edit(bufnr, before, after, ctx_lines)
    local state = M.get_state(bufnr)
    local block = append_transition(state, before, after, buf_path(bufnr), ctx_lines)
    state.baseline = vim.deepcopy(after)
    state.last_ms = vim.uv.now()
    return block
end

---@param bufnr integer
---@return string[] blocks since session start / last reset
function M.edits(bufnr)
    return M.get_state(bufnr).edits
end

---@param bufnr integer
---@return { original: string, updated: string, unified: string?, start_line: integer, ts_ms: integer }[]
function M.diff_entries(bufnr)
    return M.get_state(bufnr).diff_entries
end

--- Whether the session should roll over to a fresh context.
---@param bufnr integer
---@param max_edits integer
---@param idle_minutes integer
---@return boolean
function M.should_reset(bufnr, max_edits, idle_minutes)
    local state = M.get_state(bufnr)
    if #state.edits >= max_edits then
        return true
    end
    local idle_ms = vim.uv.now() - state.last_ms
    return idle_ms >= idle_minutes * 60 * 1000
end

--- Roll the session: keep the last `seed_count` edits as seed for the fresh
--- context, clear the running log, and re-snapshot the baseline.
---@param bufnr integer
---@param seed_count integer
function M.reset(bufnr, seed_count)
    local state = M.get_state(bufnr)
    local n = #state.edits
    local seed = {}
    for i = math.max(1, n - seed_count + 1), n do
        table.insert(seed, state.edits[i])
    end
    -- Carry the last seed_count diff-history entries into the fresh context.
    local de = state.diff_entries
    local seed_diff_entries = {}
    for i = math.max(1, #de - seed_count + 1), #de do
        table.insert(seed_diff_entries, de[i])
    end
    state.seed = seed
    state.seed_diff_entries = seed_diff_entries
    state.edits = {}
    state.diff_entries = {}
    state.baseline = get_lines(bufnr)
    state.started_ms = vim.uv.now()
    state.last_ms = vim.uv.now()
end

function M.clear(bufnr)
    M.states[bufnr] = nil
    M.diagnostic_history[bufnr] = nil
end

local severity_name = { [1] = 'ERROR', [2] = 'WARNING', [3] = 'INFORMATION', [4] = 'HINT' }

local function diagnostic_line(d)
    local row = (d.lnum or 0) + 1
    local col = (d.col or 0) + 1
    local msg = d.message or ''
    local source = d.source and d.source ~= '' and (' (source: ' .. d.source .. ')') or ''
    return ('line %d, column %d: [%s] %s%s'):format(row, col, severity_name[d.severity] or 'ERROR', msg, source)
end

---@param bufnr integer
---@param diagnostics? vim.Diagnostic[]
function M.note_diagnostics(bufnr, diagnostics)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    diagnostics = diagnostics or vim.diagnostic.get(bufnr)
    if not diagnostics or #diagnostics == 0 then
        return
    end

    local hist = M.diagnostic_history[bufnr]
    if not hist then
        hist = {}
        M.diagnostic_history[bufnr] = hist
    end
    local lines = get_lines(bufnr)
    for _, d in ipairs(diagnostics) do
        hist[#hist + 1] = {
            lnum = d.lnum,
            col = d.col,
            end_lnum = d.end_lnum,
            end_col = d.end_col,
            severity = d.severity,
            message = d.message,
            source = d.source,
            code = d.code,
            line_text = lines[(d.lnum or 0) + 1] or '',
            ts_ms = vim.uv.now(),
        }
    end

    local max_entries = tonumber(session_config().diagnostic_history_max) or 20
    while #hist > max_entries do
        table.remove(hist, 1)
    end
end

---@param bufnr integer
---@return table?
function M.recent_diagnostic_focus(bufnr)
    local hist = M.diagnostic_history[bufnr]
    if hist and #hist > 0 then
        local d = hist[#hist]
        return {
            kind = 'diagnostic',
            row = (d.lnum or 0) + 1,
            col = d.col or 0,
            diagnostic = d,
        }
    end
    local current = vim.diagnostic.get(bufnr)
    if current and #current > 0 then
        table.sort(current, function(a, b)
            if (a.severity or 99) ~= (b.severity or 99) then
                return (a.severity or 99) < (b.severity or 99)
            end
            return (a.lnum or 0) < (b.lnum or 0)
        end)
        local d = current[1]
        return {
            kind = 'diagnostic',
            row = (d.lnum or 0) + 1,
            col = d.col or 0,
            diagnostic = d,
        }
    end
    return nil
end

---@param bufnr integer
---@param focus? table
---@return string
local function diagnostic_history_text(bufnr, focus)
    local items = {}
    local seen = {}
    local hist = M.diagnostic_history[bufnr] or {}
    for i = #hist, 1, -1 do
        local d = hist[i]
        local key = table.concat({ tostring(d.lnum), tostring(d.col), tostring(d.message), tostring(d.source) }, '\t')
        if not seen[key] then
            seen[key] = true
            items[#items + 1] = d
        end
        if #items >= 8 then
            break
        end
    end

    local current = vim.diagnostic.get(bufnr)
    for _, d in ipairs(current or {}) do
        local key = table.concat({ tostring(d.lnum), tostring(d.col), tostring(d.message), tostring(d.source) }, '\t')
        if not seen[key] then
            seen[key] = true
            items[#items + 1] = d
        end
        if #items >= 12 then
            break
        end
    end

    if #items == 0 and not (focus and focus.diagnostic) then
        return ''
    end

    local out = { 'Recent LSP diagnostics:' }
    if focus and focus.diagnostic then
        out[#out + 1] = 'Focus diagnostic: ' .. diagnostic_line(focus.diagnostic)
    end
    for _, d in ipairs(items) do
        local line = diagnostic_line(d)
        if d.line_text and d.line_text ~= '' then
            line = line .. (' | text: `%s`'):format(d.line_text)
        end
        out[#out + 1] = line
    end
    return table.concat(out, '\n')
end

local function slice_lines(lines, first, last)
    local out = {}
    for i = first, last do
        table.insert(out, lines[i] or '')
    end
    return out
end

local function insert_cursor_marker(line, col0)
    col0 = math.max(0, math.min(col0 or 0, #line))
    return line:sub(1, col0) .. '<|cursor|>' .. line:sub(col0 + 1)
end

-- ---------------------------------------------------------------------------
-- recently_viewed_code_snippets: recent-buffer ring + send-time history cleanup
-- ---------------------------------------------------------------------------

-- Most-recently-visited buffers (across files), newest last. Drives the
-- cross-file snippets Mercury Edit expects in recently_viewed_code_snippets.
M.recent = {}
local RECENT_MAX = 16

--- Record that the cursor is in `bufnr` at its current row. Call on buffer enter
--- / cursor hold so snippets can be centered on the user's recent locations.
--- Snippets are always rendered from the latest buffer content at send time, so
--- only the position is stored here (a stale snapshot would invite reverts).
---@param bufnr integer
function M.note_cursor(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_name(bufnr) == '' then
        return
    end
    local row = 1
    if vim.api.nvim_get_current_buf() == bufnr then
        row = vim.api.nvim_win_get_cursor(0)[1]
    else
        local mark = vim.api.nvim_buf_get_mark(bufnr, '"')[1]
        row = mark > 0 and mark or 1
    end
    for i = #M.recent, 1, -1 do
        if M.recent[i].bufnr == bufnr then
            table.remove(M.recent, i)
        end
    end
    table.insert(M.recent, { bufnr = bufnr, row = row, ts = vim.uv.now() })
    while #M.recent > RECENT_MAX do
        table.remove(M.recent, 1)
    end
end

--- Up to `count` cross-file snippets of ~`radius`*2 lines centered on the user's
--- recent cursor rows, newest first, read from current (latest) buffer content.
---@param current_bufnr integer
---@param count integer
---@param radius integer
---@return { path: string, lines: string[] }[]
local function recent_snippets(current_bufnr, count, radius)
    local out = {}
    for i = #M.recent, 1, -1 do
        if #out >= count then
            break
        end
        local r = M.recent[i]
        if r.bufnr ~= current_bufnr and vim.api.nvim_buf_is_valid(r.bufnr) and vim.api.nvim_buf_is_loaded(r.bufnr) then
            local lines = get_lines(r.bufnr)
            if #lines > 0 then
                local row = math.max(1, math.min(r.row, #lines))
                out[#out + 1] = {
                    path = buf_path(r.bufnr),
                    lines = slice_lines(lines, math.max(1, row - radius), math.min(#lines, row + radius)),
                }
            end
        end
    end
    return out
end

--- Expand [start_row, end_row] outward to enclosing syntax-node boundaries while
--- the result stays within `max_lines`. Ranges are innermost to outermost.
local function snap_region(start_row, end_row, syntax_ranges, max_lines)
    if not syntax_ranges then
        return start_row, end_row
    end
    for _, sr in ipairs(syntax_ranges) do
        local ns = math.min(start_row, sr.start_line)
        local ne = math.max(end_row, sr.end_line)
        if (ne - ns + 1) <= max_lines then
            start_row, end_row = ns, ne
        else
            break
        end
    end
    return start_row, end_row
end

--- Build the Mercury Edit 2 tagged prompt and describe the editable region it
--- should return, following Inception's Next Edit format: cross-file snippets +
--- diagnostics + treesitter scope in recently_viewed_code_snippets, local file
--- context with a cursor-centered (syntax-snapped) code_to_edit region, and the
--- chronological range-based edit_diff_history, all within one byte budget.
---@param bufnr integer
---@param opts? { lines_before?: integer, lines_after?: integer, max_editable_lines?: integer, snippet_count?: integer, snippet_radius?: integer, max_siblings?: integer, max_prompt_bytes?: integer }
---@return string? prompt
---@return { path: string, start_row: integer, end_row: integer, original_lines: string[], context_start_row?: integer, context_end_row?: integer, prompt_bytes?: integer, max_prompt_bytes?: integer } region
---@return string? error
function M.build_inception_edit_turn(bufnr, opts)
    opts = opts or {}
    local state = M.get_state(bufnr)
    local path = buf_path(bufnr)
    local cur = get_lines(bufnr)
    if #cur == 0 then
        cur = { '' }
    end

    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col0 = pos[1], pos[2]
    row = math.max(1, math.min(row, #cur))

    local before = opts.lines_before or 5
    local after = opts.lines_after or 10
    local max_editable_lines = opts.max_editable_lines or 25

    -- Treesitter scope: snaps the editable region to syntax boundaries and feeds
    -- the treesitter_context snippet.
    local ts = nes.treesitter(bufnr, row, col0, opts.max_siblings or 4)

    local start_row = math.max(1, row - before)
    local end_row = math.min(#cur, row + after)
    start_row, end_row = snap_region(start_row, end_row, ts and ts.syntax_ranges, max_editable_lines)
    start_row = math.max(1, start_row)
    end_row = math.min(#cur, end_row)

    local original_lines = slice_lines(cur, start_row, end_row)
    local editable = slice_lines(cur, start_row, end_row)
    local cursor_idx = row - start_row + 1
    editable[cursor_idx] = insert_cursor_marker(editable[cursor_idx] or '', col0)

    local snippets = recent_snippets(bufnr, opts.snippet_count or 3, opts.snippet_radius or 10)
    local diag_text = nes.diagnostics_text(bufnr)
    local ts_text = nes.treesitter_text(ts)

    local entries = {}
    vim.list_extend(entries, state.seed_diff_entries or {})
    vim.list_extend(entries, state.diff_entries or {})

    local region = {
        path = path,
        start_row = start_row,
        end_row = end_row,
        original_lines = original_lines,
    }
    local max_bytes = opts.max_prompt_bytes or 32000
    if type(max_bytes) ~= 'number' or max_bytes < 1 or max_bytes >= math.huge or max_bytes ~= math.floor(max_bytes) then
        return nil, region, 'inception_edit.max_prompt_bytes must be a positive integer'
    end
    region.max_prompt_bytes = max_bytes

    local snippets_open = '<|recently_viewed_code_snippets|>\n'
    local snippets_close = '<|/recently_viewed_code_snippets|>\n\n'
    local file_open = '<|current_file_content|>\ncurrent_file_path: ' .. path .. '\n'
    local edit_text = '<|code_to_edit|>\n' .. table.concat(editable, '\n') .. '\n<|/code_to_edit|>\n'
    local file_close = '<|/current_file_content|>\n\n'
    local history_open = '<|edit_diff_history|>\n'
    local history_close = '<|/edit_diff_history|>\n'
    local mandatory_bytes = #snippets_open
        + #snippets_close
        + #file_open
        + #edit_text
        + #file_close
        + #history_open
        + #history_close
    if mandatory_bytes > max_bytes then
        return nil,
            region,
            ('Mercury editable region needs %d prompt bytes, exceeding max_prompt_bytes=%d; reduce lines_before/lines_after or increase duet.provider_options.inception_edit.max_prompt_bytes'):format(
                mandatory_bytes,
                max_bytes
            )
    end

    -- Reserve up to a quarter each for recent edits and supplemental snippets.
    -- Local file context gets at least half and any unused reservations.
    local remaining = max_bytes - mandatory_bytes
    local history_limit = math.floor(remaining / 4)
    local history_bytes = 0
    local history_blocks = {}
    -- A/B knob: 'unified' renders a faithful diff (fewer un-deletes), 'synthetic'
    -- the compact range block (stronger multi-site propagation). See config.lua.
    local history_format = session_config().edit_history_format or 'synthetic'
    for i = #entries, 1, -1 do
        local e = entries[i]
        local block = ((history_format == 'unified' and e.unified) or M.render_diff_entry(e, path)) .. '\n\n'
        if history_bytes + #block > history_limit then
            break
        end
        table.insert(history_blocks, 1, block)
        history_bytes = history_bytes + #block
    end

    local snippet_blocks = {}
    for _, snip in ipairs(snippets) do
        snippet_blocks[#snippet_blocks + 1] = '<|recently_viewed_code_snippet|>\ncode_snippet_file_path: '
            .. snip.path
            .. '\n'
            .. table.concat(snip.lines, '\n')
            .. '\n<|/recently_viewed_code_snippet|>\n'
    end
    if diag_text ~= '' then
        snippet_blocks[#snippet_blocks + 1] = '<|recently_viewed_code_snippet|>\ncode_snippet_file_path: diagnostics\n'
            .. diag_text
            .. '<|/recently_viewed_code_snippet|>\n'
    end
    if ts_text ~= '' then
        snippet_blocks[#snippet_blocks + 1] = '<|recently_viewed_code_snippet|>\ncode_snippet_file_path: treesitter_context\n'
            .. ts_text
            .. '<|/recently_viewed_code_snippet|>\n'
    end
    local selected_snippets = {}
    local snippet_bytes = 0
    for _, block in ipairs(snippet_blocks) do
        if snippet_bytes + #block <= math.floor(remaining / 4) then
            selected_snippets[#selected_snippets + 1] = block
            snippet_bytes = snippet_bytes + #block
        end
    end

    local context_start, context_end = start_row, end_row
    remaining = remaining - history_bytes - snippet_bytes
    local before_done, after_done = false, false
    while not (before_done and after_done) do
        -- Grow on both sides using complete lines. A giant adjacent line stops
        -- that side, preserving a contiguous excerpt and valid UTF-8.
        if not before_done then
            local line = cur[context_start - 1]
            if line and #line + 1 <= remaining then
                context_start = context_start - 1
                remaining = remaining - #line - 1
            else
                before_done = true
            end
        end
        if not after_done then
            local line = cur[context_end + 1]
            if line and #line + 1 <= remaining then
                context_end = context_end + 1
                remaining = remaining - #line - 1
            else
                after_done = true
            end
        end
    end

    local pre = slice_lines(cur, context_start, start_row - 1)
    local post = slice_lines(cur, end_row + 1, context_end)
    local prompt = snippets_open
        .. table.concat(selected_snippets)
        .. snippets_close
        .. file_open
        .. (#pre > 0 and table.concat(pre, '\n') .. '\n' or '')
        .. edit_text
        .. (#post > 0 and table.concat(post, '\n') .. '\n' or '')
        .. file_close
        .. history_open
        .. table.concat(history_blocks)
        .. history_close
    region.context_start_row = context_start
    region.context_end_row = context_end
    region.prompt_bytes = #prompt
    return prompt, region
end

--- Build the user turn for a prediction: a cursor note, the recent edits (seed +
--- running log), then the clean current file. The cursor is fed as a SEPARATE
--- note (not an inline marker) so the file/patch text stays in-distribution for
--- the apply_patch-trained model. The system prompt and tool definitions live in
--- config.lua / the backend.
---@param bufnr integer
---@param opts? { ctx_lines?: integer, current_lines?: string[], focus?: table, simulated_accept?: boolean }
---@return string
function M.build_user_turn(bufnr, opts)
    opts = opts or {}
    local state = M.get_state(bufnr)
    local path = buf_path(bufnr)
    local cur = opts.current_lines or get_lines(bufnr)

    local parts = {}

    -- Cursor as a separate channel: a note kept OUT of the file/patch text. An
    -- inline marker measurably increased reverts and got copied into patches.
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1], pos[2]
    if opts.focus and opts.focus.row then
        row = math.max(1, math.min(opts.focus.row, math.max(#cur, 1)))
        col = opts.focus.col or 0
    end
    if opts.simulated_accept then
        table.insert(
            parts,
            'Prediction focus: assume the user accepted the currently shown NES suggestion; predict the next edit after that simulated accept.'
        )
        table.insert(parts, '')
    elseif opts.focus and opts.focus.kind == 'diagnostic' then
        table.insert(
            parts,
            'Prediction focus: fix the most recent relevant LSP diagnostic. Prefer the smallest edit at or near the diagnostic line.'
        )
        table.insert(parts, '')
    end
    table.insert(
        parts,
        ('Editor cursor: line %d, column %d (1-based). That line currently reads: `%s`'):format(
            row,
            col + 1,
            cur[row] or ''
        )
    )
    table.insert(parts, '')

    local diagnostics = diagnostic_history_text(bufnr, opts.focus)
    if diagnostics ~= '' then
        table.insert(parts, diagnostics)
        table.insert(parts, '')
    end

    local all_edits = {}
    vim.list_extend(all_edits, state.seed)
    vim.list_extend(all_edits, state.edits)
    if #all_edits > 0 then
        table.insert(parts, 'Recent edits (oldest to newest):')
        table.insert(parts, '')
        table.insert(parts, table.concat(all_edits, '\n\n'))
        table.insert(parts, '')
    end

    table.insert(parts, ('Current file `%s`:'):format(path))
    table.insert(parts, '')
    table.insert(parts, table.concat(cur, '\n'))

    return table.concat(parts, '\n')
end

return M
