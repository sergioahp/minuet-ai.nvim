local helpers = require 'tests.helpers'

--- Widest message the cmdline can take without Neovim raising the hit-enter
--- prompt (see fit_cmdline in minuet.utils for where the reservations come
--- from); the spec only needs the loosest bound.
local function cmdline_budget()
    return vim.o.columns * math.max(vim.o.cmdheight, 1) - 1
end

return {
    {
        name = 'notify flattens a multi-line message into one cmdline-sized line',
        run = function()
            helpers.setup_root_config { notify = 'warn' }
            local utils = helpers.reload 'minuet.utils'

            local notifications, restore_notifications = helpers.capture_notifications()
            utils.notify(
                'Codestral returns error on streaming: ' .. vim.inspect { error = { message = ('x'):rep(400) } },
                'error',
                vim.log.levels.INFO
            )
            restore_notifications()

            helpers.expect_equal(#notifications, 1)
            local msg = notifications[1].msg
            helpers.expect_falsy(msg:find '\n', 'message must stay on one line')
            helpers.expect_truthy(
                vim.fn.strdisplaywidth(msg) <= cmdline_budget(),
                'message must fit the cmdline: ' .. vim.fn.strdisplaywidth(msg) .. ' cells'
            )
            helpers.expect_match(msg, '^Codestral returns error on streaming: ')
            helpers.expect_match(msg, '%.%.%.$')
        end,
    },
    {
        name = 'notify leaves a message that already fits untouched',
        run = function()
            helpers.setup_root_config { notify = 'warn' }
            local utils = helpers.reload 'minuet.utils'

            local notifications, restore_notifications = helpers.capture_notifications()
            utils.notify('Request timed out.', 'warn', vim.log.levels.WARN)
            restore_notifications()

            helpers.expect_equal(#notifications, 1)
            helpers.expect_equal(notifications[1].msg, 'Request timed out.')
        end,
    },
    {
        name = 'notify fits wide (double-width) text by display cells, not characters',
        run = function()
            helpers.setup_root_config { notify = 'warn' }
            local utils = helpers.reload 'minuet.utils'

            local notifications, restore_notifications = helpers.capture_notifications()
            utils.notify(('宽'):rep(400), 'error', vim.log.levels.ERROR)
            restore_notifications()

            helpers.expect_equal(#notifications, 1)
            helpers.expect_truthy(
                vim.fn.strdisplaywidth(notifications[1].msg) <= cmdline_budget(),
                'wide text must fit the cmdline: ' .. vim.fn.strdisplaywidth(notifications[1].msg) .. ' cells'
            )
        end,
    },
    {
        name = 'stream_decode reports the offending line of a streamed error',
        run = function()
            helpers.setup_root_config { notify = 'warn' }
            local utils = helpers.reload 'minuet.utils'

            local body = 'upstream connect error or disconnect/reset before headers. reset reason: connection timeout'
            local notifications, restore_notifications = helpers.capture_notifications()
            local result = utils.stream_decode(
                { code = 0, stdout = body, stderr = '', signal = 0 },
                vim.fn.tempname(),
                'Codestral',
                function(json)
                    return json.choices[1].delta.content
                end
            )
            restore_notifications()

            helpers.expect_equal(result, nil)
            helpers.expect_equal(#notifications, 1)
            helpers.expect_match(notifications[1].msg, '^Codestral returns error on streaming: upstream connect error')
        end,
    },
}
