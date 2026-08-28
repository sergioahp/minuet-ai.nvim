local helpers = require 'tests.helpers'

local function get_extmarks(bufnr, ns_id)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
end

local function get_suggestion_text(bufnr, ns_id)
    local extmarks = get_extmarks(bufnr, ns_id)
    if #extmarks == 0 then
        return nil
    end

    local details = extmarks[1][4]
    if not details or not details.virt_text then
        return nil
    end

    local lines = { details.virt_text[1][1] }
    if details.virt_lines then
        for _, line in ipairs(details.virt_lines) do
            table.insert(lines, line[1][1])
        end
    end

    return table.concat(lines, '\n')
end

return {
    {
        name = 'virtualtext.action.fire reuses cached suggestions when the stop token becomes narrower',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {
                            stop = '\n\n',
                        },
                    },
                },
            }

            local backend_calls = 0
            local pending_callback

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'alpha\nbeta' }
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()

            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha\nbeta')

            virtualtext.action.fire {
                provider_options = {
                    test = {
                        optional = {
                            stop = '\n',
                        },
                    },
                },
            }

            helpers.expect_truthy(virtualtext.action.is_visible(), 'cached suggestion should remain visible immediately')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha')
            helpers.expect_truthy(pending_callback, 'second backend request should still be in flight')

            pending_callback { 'alpha\nbeta' }

            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext caps the suffix sent to the backend via context_after_chars',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    -- constant cap of 5 chars
                    context_after_chars = 5,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return {
                        lines_before = 'abcdefghij', -- 10 chars -> budget 5
                        lines_after = '0123456789', -- 10 chars, should be cut to 5
                        opts = {},
                    }
                end,
            }, { __index = real_utils })

            local sent_context
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    sent_context = context
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'abcdefghij' }, { 1, 10 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()

            helpers.expect_truthy(sent_context, 'backend received a request')
            helpers.expect_equal(sent_context.lines_after, '01234', 'suffix capped to the budget')
            helpers.expect_truthy(sent_context.opts.is_incomplete_after, 'capping marks the suffix incomplete')

            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext anchor checks older snap points when the newest one fails',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    context_growth_slack = 100,
                    context_divergence_slack = 37,
                    max_anchors = 8,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            -- control.fresh = the prefix a fresh (no-anchor) window returns.
            -- control.a_anchors = whether a candidate whose snap prefix is 'A'
            -- is currently still buffer-valid (anchors). This lets us simulate
            -- a snap where the newest point ('B') is stale but an older one
            -- ('A') is still warm.
            local control = { fresh = 'A', a_anchors = false }
            local anchor_divergence_slacks = {}
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function(_, _, anchor)
                    if anchor then
                        table.insert(anchor_divergence_slacks, anchor.divergence_slack)
                        local ok = anchor.prev_lines_before == 'A' and control.a_anchors
                        return {
                            lines_before = anchor.prev_lines_before .. '+',
                            lines_after = 'AFT',
                            opts = { anchored = ok },
                        }
                    end
                    return { lines_before = control.fresh, lines_after = 'AFT', opts = {} }
                end,
            }, { __index = real_utils })

            local sent = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    table.insert(sent, context)
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- T1: fresh window 'A' -> establishes snap point A.
            virtualtext.action.fire()
            -- T2: snap A rejected (slack exceeded), fresh window 'B' -> snap B.
            control.fresh = 'B'
            virtualtext.action.fire()
            -- T3: newest snap B is stale, older snap A is warm.
            control.a_anchors = true
            virtualtext.action.fire()

            helpers.expect_equal(#sent, 3, 'three requests dispatched')
            helpers.expect_equal(sent[1].lines_before, 'A', 'T1 sends the fresh A window')
            helpers.expect_equal(sent[2].lines_before, 'B', 'T2 re-anchors to a fresh B window')
            -- The newest snap (B) does not match; the ring looks back and snaps
            -- to the older A, growing from it ('A+').
            helpers.expect_equal(sent[3].lines_before, 'A+', 'T3 snaps back to the older warm anchor')
            helpers.expect_truthy(sent[3].opts.anchored, 'snap-back is an anchored reuse')
            helpers.expect_equal(anchor_divergence_slacks[1], 37, 'divergence slack is passed to anchor lookup')

            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext context_before_chars sizes the prefix independently of the suffix',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    context_before_chars = 16000,
                    context_after_chars = 4000,
                    context_growth_slack = 12000,
                },
                provider_options = { test = { model = 'fixture-model', optional = {} } },
            }

            local sent = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    table.insert(sent, context)
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            -- A long doc so both sides exceed the window and the prefix would
            -- otherwise be squeezed to context_window*context_ratio.
            local lines = {}
            for i = 1, 600 do
                lines[i] = ('L%03d '):format(i) .. string.rep('x', 94)
            end
            local bufnr = helpers.create_buffer(lines, { 300, 50 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()

            vim.fn.mode = original_mode
            helpers.expect_truthy(#sent >= 1, 'a request was dispatched')
            local pre = vim.fn.strchars(sent[1].lines_before)
            local suf = vim.fn.strchars(sent[1].lines_after)
            helpers.expect_equal(pre, 16000, 'prefix gets its full context_before_chars budget')
            helpers.expect_truthy(suf <= 4000, 'suffix bounded to ~4k, not the 25% split of a 16k window')
            helpers.expect_truthy(suf >= 3900, 'suffix sized by context_after_chars near its 4k cap')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext context_back_slack pins a larger prefix; a rewind re-pins (suffix gate)',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    context_before_chars = 160,
                    context_back_slack = 80,
                    context_after_chars = 40,
                    context_growth_slack = 120,
                },
                provider_options = { test = { model = 'fixture-model', optional = {} } },
            }

            local sent = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    table.insert(sent, context)
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local lines = {}
            for i = 1, 120 do
                lines[i] = (('L%03d-'):format(i)):rep(16)
            end
            local bufnr = helpers.create_buffer(lines, { 60, 48 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(#sent, 1)
            helpers.expect_equal(vim.fn.strchars(sent[1].lines_before), 240)
            helpers.expect_equal(vim.fn.strchars(sent[1].lines_after), 40)
            helpers.expect_truthy(sent[1].opts.is_incomplete_before)
            helpers.expect_falsy(sent[1].opts.anchored)

            -- Rewind inside the backward headroom. With the suffix hard gate a
            -- rewind changes the after-cursor text, so we re-pin a fresh window
            -- rather than reuse the warm prefix behind a now-stale suffix.
            vim.api.nvim_win_set_cursor(0, { 60, 8 })
            virtualtext.action.fire()

            vim.fn.mode = original_mode
            helpers.expect_equal(#sent, 2)
            helpers.expect_falsy(sent[2].opts.anchored, 'a rewind changes the suffix, so we re-pin')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Content-based cache (no shift): the same state re-shows from cache
        -- verbatim, but a typed-ahead state (cursor advanced past the cached
        -- position) is no longer "shifted" into a partial match -- it misses
        -- and refetches.
        name = 'virtualtext content cache re-shows the same state and refetches a shifted one',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'abc', lines_after = 'xyz', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'qhello' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- First request at state 'abc' -> caches and shows 'qhello'.
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            -- Exact same state: served from cache, no new request.
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1, 'identical state is served from cache')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            -- Typed-ahead state 'bcq' is not a suffix of cached 'abc' (no shift):
            -- the cache misses and a fresh request fires.
            current = { lines_before = 'bcq', lines_after = 'xy', opts = {} }
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 2, 'a shifted state refetches instead of shifting the cache')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Forward typing grows the window (the prefix start stays put until the
        -- buffer exceeds context_window), so cached 'abc' is a *prefix* of the
        -- typed-ahead 'abcq'. The user typed the head of 'qhello', so the cache
        -- serves the stripped remainder 'hello' without a new request.
        name = 'virtualtext content cache strips the typed prefix when the window grows forward',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'abc', lines_after = 'xyz', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'qhello' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- First request at 'abc' -> caches and shows 'qhello'.
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^qhello')

            -- Typed 'q' into the completion: window grew to 'abcq'. The cache
            -- serves 'hello' (the untyped remainder), no new request.
            current = { lines_before = 'abcq', lines_after = 'xyz', opts = {} }
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1, 'a grown window is served from cache, not refetched')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^hello')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext hand typing uses the anchored cache in a long document',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                    context_before_chars = 20,
                    context_after_chars = 20,
                    context_growth_slack = 100,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'abc' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            -- The prefix is longer than its 20-character budget, so a fresh
            -- lookup window would slide after every character. Keep real text
            -- after the cursor too: suffix emptiness is unrelated to this bug.
            local bufnr = helpers.create_buffer({ string.rep('p', 100) .. 'SUFFIX' }, { 1, 100 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^abc')

            -- Type the first suggested character by hand. The cache lookup must
            -- grow from the same anchor as the request and show the remainder;
            -- a fresh sliding lookup would miss and make a second backend call.
            vim.api.nvim_buf_set_text(bufnr, 0, 100, 0, 100, { 'a' })
            vim.api.nvim_win_set_cursor(0, { 1, 101 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                'bc',
                'matching hand-typed text keeps the anchored remainder visible'
            )
            helpers.expect_equal(backend_calls, 1, 'matching hand-typed text must not refetch')

            vim.api.nvim_buf_set_text(bufnr, 0, 101, 0, 101, { 'b' })
            vim.api.nvim_win_set_cursor(0, { 1, 102 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'c')
            helpers.expect_equal(backend_calls, 1, 'successive matching characters stay on the same cache entry')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext hand typing uses the anchored cache at EOF',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                    context_before_chars = 20,
                    context_after_chars = 20,
                    context_growth_slack = 100,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'abc' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ string.rep('p', 100) }, { 1, 100 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^abc')

            vim.api.nvim_buf_set_text(bufnr, 0, 100, 0, 100, { 'a' })
            vim.api.nvim_win_set_cursor(0, { 1, 101 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'bc')
            helpers.expect_equal(backend_calls, 1, 'matching hand-typed text at EOF must not refetch')

            vim.api.nvim_buf_set_text(bufnr, 0, 101, 0, 101, { 'b' })
            vim.api.nvim_win_set_cursor(0, { 1, 102 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'c')
            helpers.expect_equal(backend_calls, 1, 'successive EOF characters stay on the same cache entry')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext cycling locks a choice that re-shows on returning to the state',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'AA', 'BB' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- State S: two suggestions, top-ranked AA shown.
            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA')

            -- Cycle to BB: this pins BB as the choice for state S.
            virtualtext.action.next()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^BB')

            -- Move to a different, incompatible state: the lock does not apply,
            -- so the natural ranking (AA) shows there.
            current = { lines_before = 'AWAY', lines_after = '', opts = {} }
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA')

            -- Return to state S: the pinned BB comes back, not the ranked AA.
            current = { lines_before = 'S', lines_after = '', opts = {} }
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^BB',
                'returning to the state re-shows the cycled (locked) choice'
            )

            -- An explicit dismiss drops the lock; next visit shows the ranked AA.
            virtualtext.action.dismiss()
            current = { lines_before = 'S', lines_after = '', opts = {} }
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA', 'dismiss clears the lock')

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext cache keeps future entries but hides them after backspace',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            local real_utils = require 'minuet.utils'
            local current_context = {
                lines_before = 'abcabc',
                lines_after = 'tail',
                opts = {},
            }

            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current_context
                end,
            }, { __index = real_utils })

            local backend_calls = 0

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'future-derived' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'abcabc' }, { 1, 6 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^future%-derived')

            current_context = {
                lines_before = 'abc',
                lines_after = 'tail',
                opts = {},
            }
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'abc' })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_falsy(
                virtualtext.action.is_visible(),
                'cache entries requested ahead of the current cursor must not render'
            )

            current_context = {
                lines_before = 'abcabc',
                lines_after = 'tail',
                opts = {},
            }
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'abcabc' })
            vim.api.nvim_win_set_cursor(0, { 1, 6 })
            virtualtext.action.fire()

            helpers.expect_equal(backend_calls, 1, 'hidden future entry should remain cached')
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^future%-derived')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext.action.next fetches instead of cycling when overrides change cache params',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {
                            stop = '\n',
                        },
                    },
                },
            }

            local backend_calls = 0
            local pending_callback

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'alpha-one', 'alpha-two' }
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^alpha%-one')

            virtualtext.action.next {
                provider_options = {
                    test = {
                        optional = {
                            stop = '\n\n',
                        },
                    },
                },
            }

            helpers.expect_equal(backend_calls, 2, 'override request should fetch a fresh completion set')
            helpers.expect_truthy(pending_callback, 'second backend request should still be in flight')
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^alpha%-one',
                'override request should not cycle through the existing completion set'
            )

            pending_callback { 'paragraph-one', 'paragraph-two' }
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^paragraph%-one')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext auto trigger fires immediately while typing when debounce and throttle are zero',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            local backend_calls = 0

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'

            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(backend_calls, 3, 'zero-debounce auto trigger should not be deferred until typing pauses')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext unintrusive mode skips auto trigger when text follows the cursor',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'unintrusive',
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback {}
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            -- Cursor in the middle of `foo(bar) ` between `(` and `bar`: text
            -- after the cursor (`bar) `) is not whitespace-only, so
            -- unintrusive mode should suppress auto-trigger.
            local bufnr = helpers.create_buffer({ 'foo(bar) ' }, { 1, 4 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'unintrusive'

            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_equal(backend_calls, 0, 'unintrusive mode must not fire when non-whitespace follows the cursor')

            -- Cursor on the trailing space at col 8: after-cursor is ` `,
            -- whitespace-only, so unintrusive mode must trigger.
            vim.api.nvim_win_set_cursor(0, { 1, 8 })
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_equal(backend_calls, 1, 'unintrusive mode must fire when only whitespace follows')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext set_auto_trigger_mode switches the per-buffer mode',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                virtualtext = { auto_trigger_mode = 'full' },
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local _, restore_notify = helpers.capture_notifications()
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'n'
            end

            virtualtext.action.set_auto_trigger_mode 'unintrusive'
            helpers.expect_equal(vim.b[bufnr].minuet_virtual_text_auto_trigger_mode, 'unintrusive')

            virtualtext.action.set_auto_trigger_mode 'off'
            helpers.expect_equal(vim.b[bufnr].minuet_virtual_text_auto_trigger_mode, 'off')

            virtualtext.action.set_auto_trigger_mode 'full'
            helpers.expect_equal(vim.b[bufnr].minuet_virtual_text_auto_trigger_mode, 'full')

            vim.fn.mode = original_mode
            restore_notify()
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext enable_auto_trigger immediately fires a completion',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'auto-fired' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'off'

            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.enable_auto_trigger()
            helpers.expect_equal(backend_calls, 1, 'enabling auto-trigger should fire a completion immediately')
            helpers.expect_truthy(virtualtext.action.is_visible(), 'ghost text should appear after enable')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext disable_auto_trigger dismisses currently visible ghost text',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'shown' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_truthy(virtualtext.action.is_visible(), 'ghost text should be visible before disable')

            virtualtext.action.disable_auto_trigger()
            helpers.expect_falsy(virtualtext.action.is_visible(), 'disabling auto-trigger should hide ghost text')

            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext disable_auto_trigger ignores in-flight auto-trigger callbacks',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
            }

            local backend_calls = 0
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    pending_callback = callback
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.set_auto_trigger_mode 'full'
            helpers.expect_equal(backend_calls, 1, 'auto-trigger should start one backend request')
            helpers.expect_truthy(pending_callback, 'backend request should be in flight')

            virtualtext.action.disable_auto_trigger()
            pending_callback { 'stale' }

            helpers.expect_falsy(
                virtualtext.action.is_visible(),
                'late auto-trigger callback should not show ghost text after disable'
            )

            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext accept_word handles multibyte keyword characters',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { ' condición = true' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_word()

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ' condición'
            end, 1000, 'accept_word should insert the full multibyte word')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext accept_until_char includes a multibyte target character',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'condición' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local original_mode = vim.fn.mode
            local original_getcharstr = vim.fn.getcharstr
            vim.fn.mode = function()
                return 'i'
            end
            vim.fn.getcharstr = function()
                return 'ó'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_until_char()

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'condició'
            end, 1000, 'accept_until_char should include the full multibyte target')

            virtualtext.action.dismiss()
            vim.fn.getcharstr = original_getcharstr
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext consecutive accept_word inserts successive words from the same suggestion',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'foo bar baz' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            -- Real headless nvim is in normal mode; mode() is mocked to 'i' so
            -- triggers fire, but nvim_win_set_cursor still clamps to the last
            -- char position. virtualedit=onemore lets the cursor sit one past
            -- the end of line, matching real insert-mode behavior so the next
            -- accept inserts at the right column.
            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_word()
            virtualtext.action.accept_word()
            virtualtext.action.accept_word()

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'foo bar baz'
            end, 1000, 'three consecutive accept_word should insert all three words in order')

            helpers.expect_equal(
                backend_calls,
                1,
                'no extra backend round-trip should be needed between accepts'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext consecutive accept_word inserts the whole suggestion with one round-trip',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'one two three four five' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            for _ = 1, 5 do
                virtualtext.action.accept_word()
            end

            helpers.wait_until(function()
                return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'one two three four five'
            end, 1000, 'five accept_word calls should insert the whole 23-char suggestion')

            helpers.expect_equal(
                backend_calls,
                1,
                'the cache-slide keeps the entry compatible, so one round-trip is enough'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext partial accept ignores delayed pre-accept callbacks',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    context_after_chars = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {
                            stop = { '\n' },
                            max_tokens = 64,
                        },
                    },
                },
            }

            local overrides = {
                provider_options = {
                    test = {
                        optional = {
                            stop = { '\n\n' },
                            max_tokens = 256,
                        },
                    },
                },
            }

            local backend_calls = 0
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    pending_callback = callback
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_lines = { 'El problema dual es', '$' }
            local bufnr = helpers.create_buffer(original_lines, { 2, 1 })
            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.next(overrides)
            helpers.expect_equal(backend_calls, 1, 'manual multiline request should start one backend request')
            helpers.expect_truthy(pending_callback, 'manual multiline request should be in flight')

            pending_callback({ 'mat(\n  2, 1;\n  -4, 1;\n)' }, false)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^mat%(')

            virtualtext.action.accept_line()
            local partially_accepted = get_suggestion_text(bufnr, virtualtext.ns_id)
            helpers.expect_match(partially_accepted, '%-4, 1;', 'partial accept should keep the original remainder')

            pending_callback({ 'mat(\n)' }, true)
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                partially_accepted,
                'late pre-accept callback must not repaint the current partial-accept remainder'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext partial accept ignores its own cursor-moved event at EOF',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    context_after_chars = 0,
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {
                            stop = { '\n\n' },
                            max_tokens = 256,
                        },
                    },
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback {
                        'mat(\n  2, 1;\n  -4, 1;\n)',
                        'mat(\n)',
                    }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'El problema dual es', '$' }, { 2, 1 })
            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.accept_line()
            local partially_accepted = get_suggestion_text(bufnr, virtualtext.ns_id)
            helpers.expect_match(partially_accepted, '%-4, 1;', 'partial accept should keep the long remainder')

            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                partially_accepted,
                'the cursor event caused by accept must not re-derive a different cached sibling'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'virtualtext fires concurrent requests and an older one still lands for its own state',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = {
                        model = 'fixture-model',
                        optional = {},
                    },
                },
            }

            -- get_context is driven by this closure var so we can advance the
            -- "cursor" between keystrokes without touching the real buffer.
            local real_utils = require 'minuet.utils'
            local before = 'a'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return { lines_before = before, lines_after = '', opts = {} }
                end,
            }, { __index = real_utils })

            -- The fake backend never invokes its callback on its own, so every
            -- request stays "in flight" until the test drives it manually.
            local backend_calls = 0
            local pending = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    table.insert(pending, callback)
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'a' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- First keystroke: cache miss -> request #1, left in flight.
            before = 'a'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            -- Second keystroke at a new position while #1 is still pending and
            -- nothing has been cached yet: it must fire its own request rather
            -- than queue behind the first (the old serialization bug).
            before = 'ab'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })

            helpers.expect_equal(backend_calls, 2, 'second keystroke must fire its own request, not queue behind the first')
            helpers.expect_equal(#pending, 2, 'both requests should be in flight concurrently')

            -- Request #2 matches the current state 'ab' and shows immediately.
            pending[2] { 'XY' }
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^XY')

            -- The OLDER request (fired at state 'a') lands later. It still caches
            -- its completion, but 'a' is not compatible with the current 'ab'
            -- state (no shift), so the display stays on #2's result.
            pending[1] { 'Z1' }
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^XY')

            -- Returning to state 'a' re-shows the older request's cached result.
            before = 'a'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^Z1',
                'the older in-flight request still lands in the cache and shows when its state returns'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Soft band: a cached completion the cursor has drifted past the soft
        -- limit (but not the hard one) is still shown, yet does not count as a
        -- fresh completion, so a background top-up request keeps firing to refill
        -- the n_completions bucket.
        name = 'virtualtext soft band shows the completion but still fires a top-up',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    cache_soft_chars_ahead = 2,
                    cache_max_chars_ahead = 20,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local before = 'p'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return { lines_before = before, lines_after = '', opts = {} }
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'abcdefghij' }
                    else
                        callback {}
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'p' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- Fresh at 'p': one completion satisfies n_completions, no top-up.
            before = 'p'
            virtualtext.action.fire()
            helpers.expect_equal(backend_calls, 1)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^abcdefghij')

            -- Typed 'abc': drift 3 is past the soft limit (2) but within the hard
            -- limit (20). The remainder still shows, but it no longer counts as
            -- fresh, so a top-up request fires.
            before = 'pabc'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^defghij',
                'soft-band completion stays shown'
            )
            helpers.expect_equal(backend_calls, 2, 'a soft-band state fires a background top-up')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Hard band: an unlocked sibling completion is hidden from the cycle list
        -- once the cursor drifts past the hard limit, while the shown/locked one
        -- stays visible (so accept_word / accept_line sliding never drops it). A
        -- cursor that returns within the band re-shows the hidden sibling.
        name = 'virtualtext hard band hides the unlocked sibling but keeps the locked one and re-shows on return',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    cache_soft_chars_ahead = 2,
                    cache_max_chars_ahead = 4,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local before = 'p'
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return { lines_before = before, lines_after = '', opts = {} }
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'abcdefAAA', 'abcdefBBB' }
                    else
                        callback {}
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'p' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            -- Two siblings at 'p'; the first is shown (and becomes the lock).
            before = 'p'
            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^abcdefAAA %(1/2%)')

            -- Typed 5 chars (drift 5 > hard 4): the unlocked sibling drops out of
            -- the list, but the locked one stays visible -- no (x/2) any more.
            before = 'pabcde'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            local shown = get_suggestion_text(bufnr, virtualtext.ns_id)
            helpers.expect_match(shown, '^fAAA', 'the locked completion survives past the hard limit')
            helpers.expect_falsy(shown:find('/2', 1, true), 'the unlocked sibling is hidden past the hard limit')

            -- Backspace to drift 2 (fresh again): the hidden sibling returns.
            before = 'pab'
            vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = bufnr })
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^cdefAAA %(1/2%)',
                'a returning cursor re-shows the cached sibling'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- With dismiss_drops_lock = false, dismiss is a temporary "get out of my
        -- way" hide: the per-state lock survives, so re-triggering at the locked
        -- state brings the cycled choice back instead of the natural ranking.
        name = 'virtualtext dismiss_drops_lock=false keeps the cycled choice across a dismiss',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    auto_trigger_mode = 'full',
                    dismiss_drops_lock = false,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { 'AA', 'BB' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            virtualtext.action.next()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^BB')

            -- Dismiss hides the ghost text but keeps the lock.
            virtualtext.action.dismiss()
            helpers.expect_falsy(virtualtext.action.is_visible(), 'dismiss still hides the ghost text')

            -- Re-trigger at the same state: the cycled BB returns, not ranked AA.
            virtualtext.action.fire()
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^BB',
                'the lock survives dismiss and re-shows the cycled choice'
            )

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Pressing "next" on the last suggestion fetches a not-yet-seen
        -- completion instead of wrapping back to the first, and cycles to it.
        name = 'virtualtext cycling past the last suggestion fetches a new distinct completion',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 3,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'AA' }
                    else
                        callback { 'BB' }
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA')

            -- At the last suggestion (1/1): fetch a new distinct completion.
            virtualtext.action.next()
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^BB',
                'cycles to the freshly fetched distinct completion'
            )
            helpers.expect_truthy(backend_calls >= 2, 'a distinct fetch fired at least one more request')

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- While the distinct fetch is in flight the loading dots show inside the
        -- counter; they clear and the view cycles once a distinct completion
        -- lands. If none ever differs, the dots clear and the last entry stays
        -- (never wrapping to the first or to an empty display).
        name = 'virtualtext distinct fetch shows loading dots and gives up onto the last entry',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 2,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            local pending = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'AA' }
                    else
                        table.insert(pending, callback)
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA')

            -- next() at the last entry: a distinct request is in flight, dots show.
            virtualtext.action.next()
            helpers.expect_truthy(pending[1], 'a distinct request is in flight')
            helpers.expect_truthy(
                get_suggestion_text(bufnr, virtualtext.ns_id):find('⋯', 1, true),
                'loading dots show while fetching'
            )

            -- The fetch keeps returning the already-seen completion: it retries up
            -- to the budget, then gives up, dropping the dots onto the last entry.
            while pending[1] do
                local cb = table.remove(pending, 1)
                cb { 'AA' }
            end
            local shown = get_suggestion_text(bufnr, virtualtext.ns_id)
            helpers.expect_match(shown, '^AA', 'gives up onto the last entry, not an empty display')
            helpers.expect_falsy(shown:find('⋯', 1, true), 'dots clear once the fetch gives up')
            helpers.expect_truthy(backend_calls >= 3, 'the distinct fetch retried before giving up')

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- prefetch_ahead = 1: cycling onto the last entry fires a background fetch
        -- for a distinct completion and appends it, keeping the user where they
        -- are, so scrolling further never blocks on a request.
        name = 'virtualtext prefetch_ahead preemptively fetches a distinct completion at the tail',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 3,
                    prefetch_ahead = 1,
                    auto_trigger_mode = 'full',
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'AA', 'BB' }
                    else
                        callback { 'CC' }
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^AA %(1/2%)')

            -- Cycle to the last (2/2): the tail prefetch appends a third entry,
            -- keeping the user on BB -> (2/3), no extra cycle and no dots.
            virtualtext.action.next()
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^BB %(2/3%)',
                'reaching the tail prefetches a distinct completion without moving the user'
            )
            helpers.expect_equal(backend_calls, 2, 'the tail prefetch fired one extra request')

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- max_display_lines = 1: a multi-line completion renders as one line of
        -- ghost text with a +N hidden-tail marker; bare accepts take only the
        -- visible portion and walk the completion line by line.
        name = 'virtualtext max_display_lines renders one line and accepts piecewise',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { '1\ny = 2\nz = 3' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '1',
                'only the first line renders'
            )

            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1' })
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '\ny = 2',
                'the remainder shows the next content line, one virt_line below'
            )

            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1', 'y = 2' })
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '\nz = 3',
                'nothing is hidden once a single content line remains'
            )

            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1', 'y = 2', 'z = 3' })
            helpers.expect_falsy(virtualtext.action.is_visible(), 'the suggestion is consumed')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Completions that only differ past the display cut render the same
        -- ghost text, so they collapse into one cyclable entry: no (1/2) whose
        -- alternatives all look identical. The hidden sibling tail is not
        -- lost -- once the shared line is accepted, the tails diverge into
        -- genuinely distinct entries again.
        name = 'virtualtext display cap collapses completions that render identically',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { '1\ny = 2', '1\nz = 3' }
                    else
                        callback {}
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '1',
                'identical visible portions collapse into one entry, so no counter shows'
            )

            -- Accepting the shared line surfaces the divergent tails as real,
            -- visibly distinct alternatives.
            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1' })
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), '\ny = 2')

            virtualtext.action.next()
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '\nz = 3 (2/2)',
                'the sibling tail cycles in as a distinct entry after the accept'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- A distinct fetch judges "seen" on the rendered portion too: a fetched
        -- completion that only differs past the display cut would paint the
        -- exact same ghost text the user cycled away from, so it must not be
        -- cycled to -- the fetch keeps retrying and eventually gives up in
        -- place.
        name = 'virtualtext distinct fetch skips completions that only differ past the display cut',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 2,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local real_utils = require 'minuet.utils'
            local current = { lines_before = 'S', lines_after = '', opts = {} }
            package.loaded['minuet.utils'] = setmetatable({
                get_context = function()
                    return current
                end,
            }, { __index = real_utils })

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    callback { 'AA\ntail-' .. backend_calls }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local bufnr = helpers.create_buffer({ 'x' }, { 1, 1 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'AA')

            virtualtext.action.next()
            local shown = get_suggestion_text(bufnr, virtualtext.ns_id)
            helpers.expect_equal(shown, 'AA', 'a same-looking fetch never cycles in')
            helpers.expect_equal(backend_calls, 3, 'the fetch retried up to the budget before giving up')

            virtualtext.action.dismiss()
            package.loaded['minuet.utils'] = real_utils
            vim.fn.mode = original_mode
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- A manual multi-line keymap lifts the cap for its own request family
        -- (virtualtext = { max_display_lines = false }), keeping the classic
        -- full multi-line ghost text.
        name = 'virtualtext max_display_lines override lifts the cap for a manual trigger',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    callback { '1\ny = 2\nz = 3' }
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire { virtualtext = { max_display_lines = false } }
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '1\ny = 2\nz = 3',
                'the override renders the whole completion'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Streamed first-line early paint: with a display cap, the visible
        -- portion is final as soon as the stream moves past it, so the ghost
        -- text paints from the partial without waiting for the request to
        -- settle; the settled completion then replaces it seamlessly.
        name = 'virtualtext paints the first line from a stream partial before the request settles',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local on_stream_partial
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    on_stream_partial = context.opts.on_stream_partial
                    pending_callback = callback
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_truthy(on_stream_partial, 'a capped trigger passes the partial hook to the backend')
            helpers.expect_falsy(virtualtext.action.is_visible(), 'nothing painted before the first line settles')

            -- Mid-stream, first line not complete yet: no paint.
            on_stream_partial '1'
            helpers.expect_falsy(virtualtext.action.is_visible(), 'an incomplete visible portion stays unpainted')

            -- The stream moved past the first line: paint it.
            on_stream_partial '1\ny = '
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), '1')

            -- Later partials do not repaint over the shown line.
            on_stream_partial '1\ny = 2\nz'
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), '1')

            -- The settled result replaces the partial: same visible line,
            -- longer hidden tail. Accepting proves the swap -- the stored
            -- partial ('1\ny = ') could not serve a complete second line.
            pending_callback({ '1\ny = 2\nz = 3' }, true)
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), '1')
            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1' })
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), '\ny = 2')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- A fully consumed suggestion frees its per-state lock. The accept
        -- itself reconsiders the cache and paints the next compatible sibling
        -- in the same synchronous event, and a later re-derive at the consumed
        -- state must not pin an empty remainder over real completions (the
        -- empty-ghost-with-(n/n) bug).
        name = 'virtualtext full accept frees the lock and re-shows the next compatible completion',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 2,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local backend_calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { '1', '1 + 2' }
                    else
                        callback {}
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^1', 'top result shows and locks')

            -- Accept the whole active suggestion ('1'). Its lock is spent; the
            -- sibling's remainder must appear within the same accept event.
            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1' })
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                ' + 2',
                'the sibling remainder paints synchronously after the full accept'
            )

            -- Consume the sibling too: nothing compatible remains, so nothing
            -- may be shown -- in particular not an empty pinned remainder.
            virtualtext.action.accept()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = 1 + 2' })
            helpers.expect_falsy(virtualtext.action.is_visible(), 'no ghost text after consuming everything')

            -- Re-derive at the consumed state (backend now returns nothing):
            -- the spent lock's empty remainder must not resurface as a ghost.
            virtualtext.action.fire()
            helpers.expect_falsy(
                virtualtext.action.is_visible(),
                'a spent lock must not pin an empty ghost text at the consumed state'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Accept-walking must keep the request pipeline warm: sliding the
        -- cache keeps the walked remainder displayable, but the slid chars
        -- count as freshness drift, so once a walk crosses the soft band the
        -- accept itself schedules a top-up (its own CursorMovedI is
        -- suppressed, so nothing else would). The landing top-up must not
        -- repaint over the walked remainder.
        name = 'virtualtext accept-walk past the soft band fires a top-up and keeps the remainder shown',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                    -- soft band: 20 chars of drift
                    cache_soft_chars_ahead = 20,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local backend_calls = 0
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    backend_calls = backend_calls + 1
                    if backend_calls == 1 then
                        callback { 'abc\nBBBBBBBBBBBBBBBBBBBBB\ntail' }
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'abc', 'first line renders')
            helpers.expect_equal(backend_calls, 1)

            -- First accept slides the entry 3 chars: still inside the soft
            -- band, so the state stays satisfied and no request fires.
            virtualtext.action.accept()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^\nBBB')
            helpers.expect_equal(backend_calls, 1, 'inside the soft band the walk stays satisfied')

            -- Second accept slides 22 more chars, past the soft band: the
            -- walked remainder is no longer fresh, so the accept schedules a
            -- top-up request at the new state.
            virtualtext.action.accept()
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^\ntail')
            helpers.expect_equal(backend_calls, 2, 'crossing the soft band fires a top-up')

            -- The top-up lands: it joins the cyclable list but must not
            -- repaint over the walked remainder the user is looking at.
            pending_callback({ 'fresher' }, true)
            helpers.expect_match(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '^\ntail',
                'the walked remainder stays the active suggestion'
            )

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Accepting part of a manual multi-line completion must not hand the
        -- display back to the auto-trigger family: its top-up would repaint the
        -- remainder with its own results, under its own display cap, dropping or
        -- reshaping the block the user was walking through.
        name = 'virtualtext accepting part of a manual family tops up in that family',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                    -- any accept-slide leaves the soft band, so the accept below
                    -- always schedules a top-up
                    cache_soft_chars_ahead = 0,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local calls = {}
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback, cfg)
                    table.insert(calls, {
                        lines_before = context.lines_before,
                        stop = (cfg.provider_options.test.optional or {}).stop,
                    })
                    if #calls == 1 then
                        callback({ 'aaa\nbbb\nccc' }, true)
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            vim.b.minuet_virtual_text_auto_trigger_mode = 'full'
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            local block = {
                provider_options = { test = { optional = { stop = '\n\n' } } },
                virtualtext = { max_display_lines = false },
            }

            virtualtext.action.fire(block)
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                'aaa\nbbb\nccc',
                'the manual family renders the whole block'
            )

            virtualtext.action.accept_line()
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'x = aaa' })
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                '\nbbb\nccc',
                'the rest of the block stays whole -- no display cap from the default family'
            )
            helpers.expect_equal(#calls, 2, 'leaving the soft band schedules a top-up')
            helpers.expect_equal(calls[2].stop, '\n\n', 'the top-up stays in the family being walked')

            -- The top-up lands: still the walked remainder, still uncapped.
            -- The top-up joins the cyclable list (hence the counter) but must not
            -- repaint over the walked remainder.
            pending_callback({ 'zzz' }, true)
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^\nbbb\nccc')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- extend_visible: asking for a bigger family while a completion is on
        -- screen continues it instead of replacing it. The hidden tail the
        -- display cap was holding back is revealed from cache straight away, the
        -- request carries the revealed text in its prompt prefix, and its result
        -- is stitched back on -- so nothing visible ever changes, it only grows.
        name = 'virtualtext extend_visible reveals the cached tail and continues past it',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local calls = {}
            local pending_callback
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback, cfg)
                    table.insert(calls, {
                        lines_before = context.lines_before,
                        stop = (cfg.provider_options.test.optional or {}).stop,
                    })
                    if #calls == 1 then
                        callback({ 'aaa\nbbb' }, true)
                    else
                        pending_callback = callback
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            local block = {
                provider_options = { test = { optional = { stop = '\n\n' } } },
                virtualtext = { max_display_lines = false, extend_visible = true },
            }

            virtualtext.action.fire()
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'aaa', 'the cap shows one line')

            virtualtext.action.next(block)
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                'aaa\nbbb',
                'the tail the cap was hiding is revealed from cache, uncapped'
            )
            helpers.expect_equal(#calls, 2)
            helpers.expect_equal(
                calls[2].lines_before,
                'x = aaa\nbbb',
                'the request continues past the revealed text'
            )
            helpers.expect_equal(calls[2].stop, '\n\n')

            pending_callback({ '\nccc' }, true)
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                'aaa\nbbb\nccc',
                'the continuation is stitched back onto the revealed text'
            )

            -- Back to the plain keymap: it asks for the default family, so it
            -- switches back to the line completion rather than cycling inside
            -- the block. Its cache is still fresh here, so no request fires.
            virtualtext.action.next()
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'aaa')
            helpers.expect_equal(#calls, 2, 'the line family is still cached at this state')

            -- Extending again finds the continuation generated a moment ago
            -- already cached: the reveal costs no request at all.
            virtualtext.action.next(block)
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'aaa\nbbb\nccc')
            helpers.expect_equal(#calls, 2, 'a cached continuation is served without a request')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- The escalated family bounds its blocks with a stop token. When the
        -- ghost text already runs past that token it is a whole block by that
        -- family's own definition, so the press is purely a reveal: the cached
        -- text is shown in full and no request goes out for a continuation the
        -- family could never display.
        name = 'virtualtext extend_visible reveals without a request past the target stop token',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local calls = 0
            package.loaded['minuet.backends.test'] = {
                complete = function(_, callback)
                    calls = calls + 1
                    callback({ 'aaa\n\nbbb' }, true)
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            virtualtext.action.fire()
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'aaa')

            virtualtext.action.next {
                provider_options = { test = { optional = { stop = '\n\n' } } },
                virtualtext = { max_display_lines = false, extend_visible = true },
            }
            helpers.expect_equal(
                get_suggestion_text(bufnr, virtualtext.ns_id),
                'aaa\n\nbbb',
                'the cached completion is revealed whole'
            )
            helpers.expect_equal(calls, 1, 'a completion already past the stop token needs no continuation')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        -- Once the escalated family is the one showing, its own keymap goes back
        -- to meaning "cycle": the user asked for a different block, not for more
        -- of this one, so the request starts at the cursor again.
        name = 'virtualtext extend_visible cycles instead of extending within its own family',
        run = function()
            helpers.setup_root_config {
                provider = 'test',
                debounce = 0,
                throttle = 0,
                n_completions = 1,
                virtualtext = {
                    debounce = 0,
                    throttle = 0,
                    max_retries = 0,
                    max_display_lines = 1,
                },
                provider_options = {
                    test = { model = 'fixture-model', optional = {} },
                },
            }

            local calls = {}
            package.loaded['minuet.backends.test'] = {
                complete = function(context, callback)
                    table.insert(calls, { lines_before = context.lines_before })
                    if #calls == 1 then
                        callback({ 'aaa' }, true)
                    elseif #calls == 2 then
                        callback({ '-more' }, true)
                    else
                        callback({ 'zzz' }, true)
                    end
                end,
            }

            local virtualtext = helpers.reload 'minuet.virtualtext'
            virtualtext.setup()

            local original_ve = vim.o.virtualedit
            vim.o.virtualedit = 'onemore'
            local bufnr = helpers.create_buffer({ 'x = ' }, { 1, 4 })
            local original_mode = vim.fn.mode
            vim.fn.mode = function()
                return 'i'
            end

            local block = {
                provider_options = { test = { optional = { stop = '\n\n' } } },
                virtualtext = { max_display_lines = false, extend_visible = true },
            }

            virtualtext.action.fire()
            virtualtext.action.next(block)
            helpers.expect_equal(calls[2].lines_before, 'x = aaa', 'the escalation continues the shown line')
            helpers.expect_equal(get_suggestion_text(bufnr, virtualtext.ns_id), 'aaa-more')

            -- Same family now: this press means "another block", so the request
            -- goes back to starting at the cursor and the display cycles onto it.
            virtualtext.action.next(block)
            helpers.expect_equal(#calls, 3)
            helpers.expect_equal(
                calls[3].lines_before,
                'x = ',
                'cycling requests from the cursor, not past the ghost text'
            )
            helpers.expect_match(get_suggestion_text(bufnr, virtualtext.ns_id), '^zzz')

            virtualtext.action.dismiss()
            vim.fn.mode = original_mode
            vim.o.virtualedit = original_ve
            helpers.delete_buffer(bufnr)
        end,
    },
}
