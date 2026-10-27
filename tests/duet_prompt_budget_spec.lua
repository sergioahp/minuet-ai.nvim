local helpers = require 'tests.helpers'

return {
    {
        name = 'Mercury prompt budget keeps complete UTF-8 lines and absolute regions in large buffers',
        run = function()
            helpers.setup_root_config()
            local session = require 'minuet.duet.session'
            local lines = {}
            for i = 1, 1100 do
                lines[i] = ('-- row %04d '):format(i) .. string.rep('ab\195\169', 20)
            end
            for _, row in ipairs { 1, 550, 1100 } do
                local bufnr = helpers.create_buffer(lines, { row, 1 })
                local prompt, region, err = session.build_inception_edit_turn(bufnr, {
                    lines_before = 1,
                    lines_after = 1,
                    max_prompt_bytes = 1600,
                })
                helpers.expect_falsy(err)
                helpers.expect_truthy(#prompt <= 1600)
                helpers.expect_equal(region.prompt_bytes, #prompt)
                helpers.expect_equal(region.start_row, math.max(1, row - 1))
                helpers.expect_equal(region.end_row, math.min(1100, row + 1))
                helpers.expect_equal(region.original_lines, vim.list_slice(lines, region.start_row, region.end_row))
                local shown = prompt:match 'current_file_path: %[No Name%]\n(.-)<|/current_file_content|>'
                shown = shown:gsub('<|/?code_to_edit|>\n', ''):gsub('<|cursor|>', '')
                helpers.expect_equal(
                    shown,
                    table.concat(vim.list_slice(lines, region.context_start_row, region.context_end_row), '\n') .. '\n'
                )
                helpers.expect_truthy(pcall(vim.str_utfindex, prompt), 'whole-line trimming must preserve UTF-8')
                if row == 1 then
                    helpers.expect_equal(region.context_start_row, 1)
                elseif row == 1100 then
                    helpers.expect_equal(region.context_end_row, 1100)
                else
                    helpers.expect_truthy(region.context_start_row > 1 and region.context_end_row < 1100)
                end
                helpers.delete_buffer(bufnr)
            end
        end,
    },
    {
        name = 'Mercury prompt budget stops context at giant adjacent lines and rejects giant editable content',
        run = function()
            helpers.setup_root_config()
            local session = require 'minuet.duet.session'
            local giant = string.rep('x', 200000)
            local bufnr = helpers.create_buffer({ 'remote before', giant, 'return 1', giant, 'remote after' }, { 3, 8 })
            local prompt, region = session.build_inception_edit_turn(bufnr, {
                lines_before = 0,
                lines_after = 0,
                max_prompt_bytes = 1024,
            })
            helpers.expect_truthy(#prompt <= 1024)
            helpers.expect_equal(region.context_start_row, 3)
            helpers.expect_equal(region.context_end_row, 3)
            helpers.expect_falsy(prompt:find('remote', 1, true), 'file context must remain contiguous')
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            local rejected, original, err =
                session.build_inception_edit_turn(bufnr, { lines_before = 0, lines_after = 0 })
            helpers.expect_falsy(rejected)
            helpers.expect_equal(original.original_lines, { giant })
            helpers.expect_match(err, 'reduce lines_before/lines_after')
            helpers.expect_match(err, 'max_prompt_bytes=32000')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'Mercury prompt budget retains newest complete history entries in chronological order',
        run = function()
            helpers.setup_root_config()
            local session = require 'minuet.duet.session'
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
            local state = session.get_state(bufnr)
            state.seed_diff_entries = { { original = 'oldest', updated = string.rep('x', 20000) } }
            state.diff_entries = {
                { original = 'first old', updated = 'first new' },
                { original = 'second old', updated = 'second new' },
                { original = 'third old', updated = 'third new' },
            }
            local prompt = session.build_inception_edit_turn(bufnr, { max_prompt_bytes = 1600 })
            helpers.expect_truthy(#prompt <= 1600)
            helpers.expect_falsy(prompt:find('oldest', 1, true))
            helpers.expect_match(prompt, '%-first old\n%+first new\n\n%-%-%-')
            local first = prompt:find('first new', 1, true)
            local second = prompt:find('second new', 1, true)
            local third = prompt:find('third new', 1, true)
            helpers.expect_truthy(first < second and second < third)
            helpers.expect_equal(select(2, prompt:gsub('@@ %-1,1 %+1,1 @@', '')), 3)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'Mercury prompt budget bounds giant diagnostics, syntax and cross-file snippet blocks together',
        run = function()
            helpers.setup_root_config()
            local session = require 'minuet.duet.session'
            local nes = require 'minuet.duet.nes_context'
            local saved_diag, saved_ts = nes.diagnostics_text, nes.treesitter_text
            local other, bufnr
            local ok, err = xpcall(function()
                other = helpers.create_buffer { string.rep('other file ', 20000) }
                vim.api.nvim_buf_set_name(other, 'budget-other.lua')
                session.note_cursor(other)
                bufnr = helpers.create_buffer({ 'before', 'return 1', 'after' }, { 2, 8 })
                nes.diagnostics_text = function()
                    return string.rep('diagnostic ', 20000)
                end
                nes.treesitter_text = function()
                    return string.rep('signature ', 20000)
                end
                local prompt = session.build_inception_edit_turn(
                    bufnr,
                    { lines_before = 0, lines_after = 0, max_prompt_bytes = 1024 }
                )
                helpers.expect_truthy(#prompt <= 1024)
                helpers.expect_match(prompt, '<|recently_viewed_code_snippets|>\n<|/recently_viewed_code_snippets|>')
                helpers.expect_match(prompt, 'before\n<|code_to_edit|>')
            end, debug.traceback)
            nes.diagnostics_text, nes.treesitter_text = saved_diag, saved_ts
            helpers.delete_buffer(bufnr)
            helpers.delete_buffer(other)
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'Mercury prompt budget accepts exact mandatory size and validates invalid caps',
        run = function()
            helpers.setup_root_config()
            local session = require 'minuet.duet.session'
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
            local prompt = session.build_inception_edit_turn(bufnr)
            local exact = session.build_inception_edit_turn(bufnr, { max_prompt_bytes = #prompt })
            helpers.expect_equal(exact, prompt)
            local rejected, _, err = session.build_inception_edit_turn(bufnr, { max_prompt_bytes = #prompt - 1 })
            helpers.expect_falsy(rejected)
            helpers.expect_match(err, 'exceeding max_prompt_bytes')
            for _, cap in ipairs { -1, 0, 1.5, math.huge, '32000' } do
                local invalid, _, invalid_error = session.build_inception_edit_turn(bufnr, { max_prompt_bytes = cap })
                helpers.expect_falsy(invalid)
                helpers.expect_match(invalid_error, 'positive integer')
            end
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'Mercury oversized editable regions return callback errors without invoking transport',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'inception_edit',
                    provider_options = {
                        inception_edit = {
                            max_prompt_bytes = 512,
                            lines_before = 0,
                            lines_after = 0,
                        },
                    },
                },
            }
            local common = require 'minuet.duet.backends.common'
            local saved_start = common.start_job
            local bufnr = helpers.create_buffer({ string.rep('x', 200000) }, { 1, 0 })
            local result
            common.start_job = function()
                error 'oversized prompt must not start transport'
            end
            local ok, err = xpcall(function()
                require('minuet.duet.chat').request({}, {}, function(reply)
                    result = reply
                end, { bufnr = bufnr, mode = 'manual' })
                helpers.expect_match(result.error, 'max_prompt_bytes=512')
                helpers.expect_equal(result.inspect.outcome, 'request setup failed')
            end, debug.traceback)
            common.start_job = saved_start
            helpers.delete_buffer(bufnr)
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'Mercury bounded prompts apply transport replacements to original large-buffer rows',
        run = function()
            local original_api_key = vim.env.INCEPTION_API_KEY
            local bufnr
            local ok, err = xpcall(function()
                vim.env.INCEPTION_API_KEY = 'test-key'
                helpers.setup_root_config {
                    curl_cmd = vim.fn.getcwd() .. '/tests/scripts/mock_inception_edit.sh',
                    duet = {
                        provider = 'inception_edit',
                        request_timeout = 5,
                        provider_options = {
                            inception_edit = {
                                lines_before = 0,
                                lines_after = 0,
                                max_prompt_bytes = 800,
                            },
                        },
                    },
                }
                local duet = helpers.reload 'minuet.duet'
                duet.setup()
                local lines = {}
                for i = 1, 1100 do
                    lines[i] = '-- original buffer row ' .. i .. string.rep('x', 100)
                end
                lines[1], lines[550], lines[1100] = 'return 1', 'return 1', 'return 1'
                bufnr = helpers.create_buffer(lines, { 550, 8 })
                require('minuet.duet.session').rebase(bufnr)
                duet.action.predict()
                helpers.wait_until(function()
                    return duet.action.is_visible()
                end, 3000, 'bounded Mercury prediction did not become visible')
                duet.action.apply()
                lines[550] = 'return 42'
                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines)
                local turn = duet.history[#duet.history].turns[1]
                helpers.expect_truthy(#turn.prompt <= 800)
                helpers.expect_equal(turn.region.start_row, 550)
                helpers.expect_equal(turn.region.end_row, 550)
                helpers.expect_truthy(turn.region.context_start_row > 1)
            end, debug.traceback)
            vim.env.INCEPTION_API_KEY = original_api_key
            helpers.delete_buffer(bufnr)
            if not ok then
                error(err)
            end
        end,
    },
}
