-- Run from the repository root with INCEPTION_API_KEY set:
-- nvim --headless -u NONE -i NONE -n -l experiments/duet-nes/scripts/validate_mercury_context.lua
local helpers = require 'tests.helpers'
helpers.ensure_runtime()
assert(vim.env.INCEPTION_API_KEY and vim.env.INCEPTION_API_KEY ~= '', 'INCEPTION_API_KEY is required')

local output = vim.fn.getcwd() .. '/tmp/mercury-context/mercury-edit-2_cap-32000_' .. os.date '!%Y-%m-%d_%H-%M-%S'
assert(vim.fn.isdirectory(output) == 0, 'output directory already exists')
vim.fn.mkdir(output, 'p')
local source_path = 'lua/minuet/duet/init.lua'
local source = vim.fn.readfile(source_path)
local baseline_revision = '79d0315'
local baseline = vim.system({ 'git', 'show', baseline_revision .. ':lua/minuet/duet/session.lua' }, { text = true })
    :wait()
assert(baseline.code == 0, baseline.stderr)
local declaration_row
for row, line in ipairs(source) do
    if line:find('local memory_entry = not queue and remember_shown(ctx.bufnr, patch)', 1, true) then
        declaration_row = row
        break
    end
end
assert(declaration_row, 'rename fixture declaration not found')

local results = {
    model = 'mercury-edit-2',
    endpoint = 'https://api.inceptionlabs.ai/v1/edit/completions',
    source = source_path,
    source_lines = #source,
    baseline_revision = baseline_revision,
    token_limit = 1000000,
    usd_limit = 0.5,
    token_upper_bound_reserved = 0,
    usage_tokens_reported = 0,
    list_price_usd_reported = 0,
    cases = {},
}

---@param path string
---@param value any
local function write_json(path, value)
    vim.fn.writefile({ vim.json.encode(value) }, path)
end

print('output: ' .. output)
for _, copies in ipairs { 1, 4 } do
    for _, variant in ipairs { 'full', 'bounded' } do
        helpers.setup_root_config {
            request_log = false,
            duet = {
                provider = 'inception_edit',
                request_timeout = 45,
                session = { auto_trigger = false, max_attempts = 1 },
                provider_options = { inception_edit = { max_prompt_bytes = 32000, max_tokens = 1000 } },
            },
        }
        if variant == 'full' then
            package.loaded['minuet.duet.session'] = assert(loadstring(baseline.stdout))()
        end
        local session = require 'minuet.duet.session'
        local duet = require 'minuet.duet'
        duet.setup()
        local lines = {}
        for _ = 1, copies do
            vim.list_extend(lines, source)
        end
        local offset = math.floor(copies / 2) * #source
        local row = offset + declaration_row
        local bufnr = helpers.create_buffer(lines, { row, 0 })
        vim.api.nvim_buf_set_name(bufnr, output .. '/fixture_' .. copies .. '_' .. variant .. '.lua')
        session.rebase(bufnr)
        lines[row] = lines[row]:gsub('local memory_entry =', 'local shown_memory =', 1)
        vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { lines[row] })
        vim.api.nvim_win_set_cursor(0, { row, #lines[row] - 1 })
        session.capture(bufnr, 3)
        local expected = vim.deepcopy(lines)
        assert(expected[row + 6]:find('memory_entry = memory_entry', 1, true), 'rename fixture use not found')
        expected[row + 6] = expected[row + 6]:gsub('memory_entry = memory_entry', 'memory_entry = shown_memory', 1)
        local name = ('source-%d-lines_%s'):format(#lines, variant)
        local case_dir = output .. '/' .. name
        vim.fn.mkdir(case_dir, 'p')
        local case = {
            name = name,
            variant = variant,
            copies = copies,
            lines = #lines,
            cursor_row = row,
            started_at = os.date '!%Y-%m-%dT%H:%M:%SZ',
        }
        results.cases[#results.cases + 1] = case

        -- Keep transport scratch inside the run directory. Reserve a deliberately
        -- conservative byte-based token bound before every network call; errors
        -- and timeouts keep their reservation and there are no automatic retries.
        require('minuet.duet.utils').make_tmp_file = function(body)
            local encoded = vim.json.encode(body)
            local upper = 2 * #encoded + body.max_tokens + 4096
            assert(results.token_upper_bound_reserved + upper <= results.token_limit, 'token budget would be exceeded')
            assert(
                (results.token_upper_bound_reserved + upper) * 0.75 / 1000000 <= results.usd_limit,
                'USD ceiling would be exceeded'
            )
            results.token_upper_bound_reserved = results.token_upper_bound_reserved + upper
            case.token_upper_bound_reserved = upper
            case.prompt_bytes = #body.messages[1].content
            write_json(case_dir .. '/request.json', body)
            vim.fn.writefile({ encoded }, case_dir .. '/transport.json')
            write_json(output .. '/results.json', results)
            return case_dir .. '/transport.json'
        end

        local started = vim.uv.hrtime()
        print(name .. ': requesting')
        duet.action.predict()
        local completed = vim.wait(50000, function()
            return duet.last and duet.last.outcome ~= 'pending'
        end, 25)
        case.elapsed_ms = (vim.uv.hrtime() - started) / 1000000
        case.completed = completed
        if not completed then
            require('minuet.duet.backends.common').terminate_all_jobs()
        end
        local record = duet.last or {}
        local turn = (record.turns or {})[1] or {}
        case.outcome = record.outcome
        case.error = turn.error
        case.finish_reason = turn.finish_reason
        case.region = turn.region
        case.usage = turn.response and turn.response.usage or nil
        case.preview_visible = duet.action.is_visible()
        write_json(case_dir .. '/inspect.json', record)
        if turn.response_raw then
            vim.fn.writefile({ turn.response_raw }, case_dir .. '/response.json')
        end
        local usage = case.usage or {}
        results.usage_tokens_reported = results.usage_tokens_reported + (usage.total_tokens or 0)
        results.list_price_usd_reported = results.list_price_usd_reported
            + ((usage.prompt_tokens or 0) * 0.25 + (usage.completion_tokens or 0) * 0.75) / 1000000
        if case.preview_visible then
            duet.action.apply()
        end
        local actual = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        case.exact_expected_edit = vim.deep_equal(actual, expected)
        case.buffer_unchanged = vim.deep_equal(actual, lines)
        case.outside_region_unchanged = true
        if turn.region then
            local region = turn.region
            local delta = #actual - #lines
            for i = 1, region.start_row - 1 do
                case.outside_region_unchanged = case.outside_region_unchanged and actual[i] == lines[i]
            end
            for i = region.end_row + 1, #lines do
                case.outside_region_unchanged = case.outside_region_unchanged and actual[i + delta] == lines[i]
            end
        end
        vim.fn.writefile(actual, case_dir .. '/applied.lua')
        write_json(output .. '/results.json', results)
        print(
            ('%s: bytes=%d tokens=%d outcome=%s expected_edit=%s'):format(
                name,
                case.prompt_bytes or 0,
                usage.total_tokens or 0,
                tostring(case.outcome),
                tostring(case.exact_expected_edit)
            )
        )
        helpers.delete_buffer(bufnr)
        if not completed or (case.error and case.error:lower():find('authentication', 1, true)) then
            break
        end
    end
end
print(
    ('reported_tokens=%d reserved_token_bound=%d list_price_usd=%.6f'):format(
        results.usage_tokens_reported,
        results.token_upper_bound_reserved,
        results.list_price_usd_reported
    )
)
vim.cmd 'qa!'
