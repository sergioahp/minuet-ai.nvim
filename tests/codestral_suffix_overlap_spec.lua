local helpers = require 'tests.helpers'

---@class SuffixOverlapTestOptions
---@field text string
---@field suffix? string
---@field enabled? boolean
---@field stream? boolean
---@field chunks? string[]
---@field template_suffix? string
---@field trim_incomplete_tail_line? boolean
---@field finish_reason? string

---@param opts SuffixOverlapTestOptions
---@return string[] items
---@return string[] partials
local function run_fim(opts)
    local root = helpers.setup_root_config {
        n_completions = 1,
        fim_filter_context = false,
    }
    local base = helpers.reload 'minuet.backends.openai_base'
    local common = require 'minuet.backends.common'
    local utils = require 'minuet.utils'
    local saved = {
        make_tmp_file = utils.make_tmp_file,
        make_curl_args = utils.make_curl_args,
        stream_decode = utils.stream_decode,
        no_stream_decode = utils.no_stream_decode,
        start_job = common.start_job,
        terminate = common.terminate_all_jobs,
    }
    local items, partials = {}, {}
    local ok, err = pcall(function()
        utils.make_tmp_file = function()
            return vim.fn.getcwd() .. '/tmp/codestral-suffix-overlap-request.json'
        end
        utils.make_curl_args = function()
            return {}
        end
        utils.stream_decode = function()
            return opts.text
        end
        utils.no_stream_decode = utils.stream_decode
        common.terminate_all_jobs = function() end
        common.start_job = function(_, _, handlers)
            for _, text in ipairs(opts.chunks or {}) do
                handlers.on_stdout('data: ' .. vim.json.encode {
                    choices = { { delta = { content = text } } },
                } .. '\n\n')
            end
            handlers.on_exit({ pid = 1 }, {
                code = 0,
                stdout = vim.json.encode { choices = { { finish_reason = opts.finish_reason or 'stop' } } },
            })
            return { pid = 1 }
        end
        base.complete_openai_fim_base({
            name = 'Codestral',
            model = 'codestral-latest',
            end_point = 'https://example.test/v1/fim/completions',
            api_key = function()
                return 'test-key'
            end,
            stream = opts.stream ~= false,
            optional = {},
            transform = {},
            trim_suffix_overlap = opts.enabled,
            template = {
                prompt = function(before)
                    return before
                end,
                suffix = function(_, after)
                    return opts.template_suffix or after
                end,
            },
        }, function(json)
            return json.choices[1].delta.content
        end, {
            lines_before = 'prefix',
            lines_after = opts.suffix,
            opts = {
                trim_incomplete_tail_line = opts.trim_incomplete_tail_line,
                on_stream_partial = function(text)
                    table.insert(partials, text)
                end,
            },
        }, function(result)
            items = result
        end, root.config)
    end)
    for name, fn in pairs(saved) do
        if name == 'start_job' then
            common.start_job = fn
        elseif name == 'terminate' then
            common.terminate_all_jobs = fn
        else
            utils[name] = fn
        end
    end
    if not ok then
        error(err, 0)
    end
    return items, partials
end

local cases = {
    {
        name = 'Codestral suffix trim removes the longest exact identifier overlap without normalizing whitespace',
        run = function()
            helpers.setup_root_config()
            local trim = require('minuet.utils').trim_codestral_suffix_overlap
            helpers.expect_equal(trim('\n  new retained_name  ', 'retained_name  + next'), '\n  new ')
            helpers.expect_equal(trim('new abcdabcd', 'abcdabcd later'), 'new ')
            helpers.expect_equal(trim('new _a12', '_a12 later'), 'new ')
            helpers.expect_equal(trim('retained_name', 'retained_name later'), '')
            helpers.expect_equal(trim('new retained_name later', 'retained_name'), 'new retained_name later')
        end,
    },
    {
        name = 'Codestral suffix trim preserves short identifiers, digits, delimiters and nonmatching whitespace',
        run = function()
            helpers.setup_root_config()
            local trim = require('minuet.utils').trim_codestral_suffix_overlap
            helpers.expect_equal(trim('new abc', 'abc later'), 'new abc')
            helpers.expect_equal(trim('3084, 3086', ', 3086, 3088'), '3084, 3086')
            helpers.expect_equal(trim('{', '{nested}'), '{')
            helpers.expect_equal(trim(')', ') + next'), ')')
            helpers.expect_equal(trim('new name ', 'name + next'), 'new ')
            helpers.expect_equal(trim('new name ', 'name\t+ next'), 'new name ')
            helpers.expect_equal(trim('new \n', '\nnext'), 'new \n')
            helpers.expect_equal(trim('text', ''), 'text')
            helpers.expect_equal(trim('text', nil), 'text')
            helpers.expect_equal(trim(nil, 'name'), nil)
        end,
    },
    {
        name = 'Codestral suffix trim preserves UTF-8 bytes outside an ASCII identifier overlap',
        run = function()
            helpers.setup_root_config()
            local trim = require('minuet.utils').trim_codestral_suffix_overlap
            local prefix = vim.fn.nr2char(233) .. ' '
            local after = 'name' .. vim.fn.nr2char(0x03B1)
            helpers.expect_equal(trim(prefix .. after, after .. ' later'), prefix)
        end,
    },
    {
        name = 'Codestral streamed previews trim a copy without changing the underlying stream accumulator',
        run = function()
            local items, partials = run_fim {
                text = 'new retained_name continues',
                suffix = 'retained_name',
                enabled = true,
                chunks = { 'new retained_name', ' continues' },
            }
            helpers.expect_equal(partials, { 'new ', 'new retained_name continues' })
            helpers.expect_equal(items, { 'new retained_name continues' })
        end,
    },
    {
        name = 'Codestral suffix trim uses buffer context rather than decorated request suffix',
        run = function()
            local items = run_fim {
                text = 'new retained_name',
                suffix = 'retained_name + next',
                template_suffix = 'decorated suffix',
                enabled = true,
            }
            helpers.expect_equal(items, { 'new ' })
        end,
    },
    {
        name = 'Codestral suffix trim runs after dropping a token-limited incomplete tail line',
        run = function()
            local items = run_fim {
                text = 'new retained_name\ntruncated',
                suffix = 'retained_name + next',
                enabled = true,
                trim_incomplete_tail_line = true,
                finish_reason = 'length',
            }
            helpers.expect_equal(items, { 'new ' })
        end,
    },
    {
        name = 'Codestral suffix trim drops a final response made entirely of repeated following text',
        run = function()
            local items = run_fim {
                text = 'retained_name',
                suffix = 'retained_name + next',
                enabled = true,
            }
            helpers.expect_equal(items, {})
        end,
    },
    {
        name = 'Codestral suffix trim defaults on at the provider and respects per-call disabling',
        run = function()
            local root = helpers.setup_root_config()
            root.config.provider_options.codestral.api_key = function()
                return 'test-key'
            end
            local base = helpers.reload 'minuet.backends.openai_base'
            local provider = helpers.reload 'minuet.backends.codestral'
            local saved = base.complete_openai_fim_base
            local seen = {}
            local ok, err = pcall(function()
                base.complete_openai_fim_base = function(options)
                    table.insert(seen, options.trim_suffix_overlap)
                end
                provider.complete({}, function() end)
                local override = vim.deepcopy(root.config)
                override.codestral_trim_suffix_overlap = false
                provider.complete({}, function() end, override)
                helpers.expect_equal(seen, { true, false })
                helpers.expect_equal(root.config.codestral_trim_suffix_overlap, true)
            end)
            base.complete_openai_fim_base = saved
            if not ok then
                error(err, 0)
            end
        end,
    },
}

for _, stream in ipairs { true, false } do
    table.insert(cases, {
        name = 'Codestral suffix trim cleans ' .. (stream and 'streamed' or 'nonstreamed') .. ' final responses',
        run = function()
            local items = run_fim {
                text = 'new retained_name',
                suffix = 'retained_name + next',
                enabled = true,
                stream = stream,
            }
            helpers.expect_equal(items, { 'new ' })
        end,
    })
end

for _, enabled in ipairs { false, 'unset' } do
    table.insert(cases, {
        name = 'FIM suffix trim leaves output untouched when ' .. tostring(enabled),
        run = function()
            local flag = enabled
            if flag == 'unset' then
                flag = nil
            end
            local items = run_fim {
                text = 'new retained_name',
                suffix = 'retained_name + next',
                enabled = flag,
            }
            helpers.expect_equal(items, { 'new retained_name' })
        end,
    })
end

return cases
