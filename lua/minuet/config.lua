local default_prompt_prefix_first = [[
You are an AI code completion engine. Provide contextually appropriate completions:
- Code completions in code context
- Comment/documentation text in comments
- String content in string literals
- Prose in markdown/documentation files

Input markers:
- `<contextAfterCursor>`: Context after cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Context before cursor
]]

local default_prompt = default_prompt_prefix_first
    .. [[

Note that the user input will be provided in **reverse** order: first the
context after cursor, followed by the context before cursor.
]]

local default_guidelines = [[
Guidelines:
1. Offer completions after the `<cursorPosition>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker <endCompletion>.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result directly.
6. Keep each completion option concise, limiting it to a single line or a few lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's existing code around <cursorPosition>.]]

local default_few_shots = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>]],
    },
    {
        role = 'assistant',
        content = [[
let processed = item;
        if (options.uppercase) {
            processed = processed.toUpperCase();
        }
        if (options.removeSpaces) {
            processed = processed.replace(/\s+/g, '');
        }
        result.push(processed);
    }
<endCompletion>
if (typeof item === 'string') {
            let processed = item;
            if (options.uppercase) {
                processed = processed.toUpperCase();
            }
            if (options.removeSpaces) {
                processed = processed.replace(/\s+/g, '');
            }
            result.push(processed);
        } else {
            result.push(item);
        }
    }
<endCompletion>
]],
    },
}

local default_few_shots_prefix_first = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});]],
    },
    default_few_shots[2],
}

local n_completion_template = '8. Provide at most %d completion items.'

-- use {{{ and }}} to wrap placeholders, which will be further processesed in other function
local default_system_template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}'

local default_fim_prompt = function(context_before_cursor, _, _)
    local utils = require 'minuet.utils'
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    context_before_cursor = language .. '\n' .. tab .. '\n' .. context_before_cursor

    return context_before_cursor
end

local default_fim_suffix = function(_, context_after_cursor, _)
    return context_after_cursor
end

---@class minuet.ChatInputExtraInfo
---@field is_incomplete_before boolean
---@field is_incomplete_after boolean

---@alias minuet.ChatInputFunction fun(context_before_cursor: string, context_after_cursor: string, opts: minuet.ChatInputExtraInfo): string
---@alias minuet.FIMTemplateFunction minuet.ChatInputFunction

--- Configuration for formatting chat input to the LLM
---@class minuet.ChatInput
---@field template string Template string with placeholders for context parts
---@field language minuet.ChatInputFunction function to add language comment based on filetype
---@field tab minuet.ChatInputFunction function to add indentation style comment
---@field context_before_cursor minuet.ChatInputFunction function to process text before cursor
---@field context_after_cursor minuet.ChatInputFunction function to process text after cursor

---@type minuet.ChatInput
local default_chat_input = {
    template = '{{{language}}}\n{{{tab}}}\n<contextAfterCursor>\n{{{context_after_cursor}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>',
    language = function(_, _, _)
        local utils = require 'minuet.utils'
        return utils.add_language_comment()
    end,
    tab = function(_, _, _)
        local utils = require 'minuet.utils'
        return utils.add_tab_comment()
    end,
    context_before_cursor = function(context_before_cursor, _, opts)
        if opts.is_incomplete_before then
            -- Remove first line when context is incomplete at start
            local _, rest = context_before_cursor:match '([^\n]*)\n(.*)'
            return rest or context_before_cursor
        end
        return context_before_cursor
    end,
    context_after_cursor = function(_, context_after_cursor, opts)
        if opts.is_incomplete_after then
            -- Remove last line when context is incomplete at end
            local content = context_after_cursor:match '(.*)[\n][^\n]*$'
            return content or context_after_cursor
        end
        return context_after_cursor
    end,
}

---@type minuet.ChatInput
local default_chat_input_prefix_first = vim.deepcopy(default_chat_input)
default_chat_input_prefix_first.template =
    '{{{language}}}\n{{{tab}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}'

local M = {
    -- Enable or disable auto-completion. Note that you still need to add
    -- Minuet to your cmp/blink sources. This option controls whether cmp/blink
    -- will attempt to invoke minuet when minuet is included in cmp/blink
    -- sources. This setting has no effect on manual completion; Minuet will
    -- always be enabled when invoked manually. You can use the command
    -- `MinuetToggleCmp/Blink` to toggle this option.
    cmp = {
        enable_auto_complete = true,
    },
    blink = {
        enable_auto_complete = true,
    },
    -- LSP is recommended only for built-in completion. If you are using
    -- `cmp` or `blink`, utilizing LSP for code completion from Minuet is *not*
    -- recommended.
    lsp = {
        enabled_ft = {},
        -- Filetypes excluded from LSP activation. Useful when `enabled_ft` = { '*' }
        disabled_ft = {},
        completion = {
            enable = true,
            -- if true, warn the user that they should use the native source
            -- instead when the user is using blink or nvim-cmp.
            warn_on_blink_or_cmp = true,
            -- See README section [Built-in Completion, Mini.Completion, and LSP
            -- Setup] for more details on this option.
            adjust_indentation = true,
            -- Enables automatic completion triggering using `vim.lsp.completion.enable`
            enabled_auto_trigger_ft = {},
            -- Filetypes excluded from autotriggering. Useful when `enabled_auto_trigger_ft` = { '*' }
            disabled_auto_trigger_ft = {},
        },
        inline_completion = {
            enable = false,
            -- if true, warn the user when LSP inline completion is enabled
            -- while Minuet virtual text is also configured for use.
            warn_on_virtualtext = true,
            -- if true, warn the user when both LSP completion and inline
            -- completion are enabled. Enabling only one of them is recommended.
            warn_on_lsp_completion = true,
            -- Enables automatic inline completion for these filetypes.
            enabled_auto_trigger_ft = {},
            -- Filetypes excluded from inline completion autotriggering.
            disabled_auto_trigger_ft = {},
        },
    },
    virtualtext = {
        -- Specify the filetypes to enable automatic virtual text completion,
        -- e.g., { 'python', 'lua' }. Note that you can still invoke manual
        -- completion even if the filetype is not on your auto_trigger_ft list.
        auto_trigger_ft = {},
        -- specify file types where automatic virtual text completion should be
        -- disabled. This option is useful when auto-completion is enabled for
        -- all file types i.e., when auto_trigger_ft = { '*' }
        auto_trigger_ignore_ft = {},
        -- Auto-trigger mode applied to buffers matched by `auto_trigger_ft`.
        --   'off'         - never auto-trigger (manual fires still work)
        --   'unintrusive' - only auto-trigger when the text on the current
        --                   line after the cursor is whitespace-only, so the
        --                   ghost text never overlays existing code
        --   'full'        - auto-trigger anywhere on the line
        -- Switch at runtime with `:Minuet virtualtext mode {off|unintrusive|full}`
        -- or `require('minuet.virtualtext').action.set_auto_trigger_mode(mode)`.
        -- Per-buffer override: `vim.b.minuet_virtual_text_auto_trigger_mode`.
        auto_trigger_mode = 'full',
        keymap = {
            accept = nil,
            accept_line = nil,
            -- accept n lines (prompts for number)
            accept_n_lines = nil,
            -- accept next word (word chars) or single non-word char
            accept_word = nil,
            -- accept up to and including the next occurrence of a prompted char (like vim's f)
            accept_until_char = nil,
            -- Cycle to next completion item, or manually invoke completion
            next = nil,
            -- Cycle to prev completion item, or manually invoke completion
            prev = nil,
            dismiss = nil,
        },
        -- Whether show virtual text suggestion when the completion menu
        -- (nvim-cmp or blink-cmp) is visible.
        show_on_completion_menu = false,
        -- Render at most this many content lines (lines with non-whitespace) of
        -- the active suggestion as ghost text; blank lines before the cut are
        -- kept. Rendering only: generation is unaffected, the full multi-line
        -- completion stays cached and is consumed piecewise -- a bare accept
        -- takes just the visible portion, and the hidden tail re-surfaces as
        -- the next line(s) while the cursor moves into it. With a cap active,
        -- a streamed completion also paints as soon as its visible portion is
        -- final in the stream (~the first newline) instead of at request exit,
        -- so dropping a `stop = '\n'` in favor of multi-line generation does
        -- not cost first-paint latency. Per-trigger overridable; a manual
        -- multi-line keymap lifts the cap for its own request family with
        --   action.next { virtualtext = { max_display_lines = false } }
        -- With a cap active, completions that only differ past the display cut
        -- render the same ghost text and collapse into one cyclable entry, so
        -- the (x/y) counter and next/prev only ever offer visibly different
        -- alternatives. nil/false renders everything (default).
        max_display_lines = nil,
        -- Whether asking for this family while ANOTHER family's ghost text is on
        -- screen continues that text instead of replacing it. The request is
        -- fired with the visible completion appended to the prompt prefix and
        -- its result is stitched back onto it, so the ghost text only ever grows
        -- -- the escalation reads as "reveal more" rather than a different
        -- suggestion. The reveal starts from the local cache: the tail a display
        -- cap was hiding shows immediately, and when a continuation generated
        -- earlier is already cached no request is fired at all. Meant for a
        -- manual keymap that escalates the cheap autotrigger family into a
        -- bigger one, e.g.
        --   action.next(vim.tbl_deep_extend('force', block_opts, {
        --     virtualtext = { max_display_lines = false, extend_visible = true },
        --   }))
        -- Leave it off (default) for the family the plain next/prev keymap asks
        -- for, which is meant to cycle to a *different* completion; pressing that
        -- keymap while the escalated family is showing switches back to it.
        extend_visible = false,
        -- Maximum number of response pool entries kept per buffer. The pool is
        -- the local cache of past completions; a larger pool lets us recognise
        -- more previously-seen buffer states (so a returning cursor re-shows a
        -- suggestion without a round-trip) and gives the anchor more recent
        -- prefixes to snap back to. Cheap to keep large -- entries are small.
        pool_size = 128,
        -- Number of recent anchor "snap points" kept per buffer. When the newest
        -- snap no longer anchors, the ring is searched newest-first for a
        -- still-valid prefix+suffix pair instead of paying for a cold re-anchor.
        max_anchors = 8,
        -- Maximum automatic retry triggers fired per session when the pool
        -- yields fewer than n_completions effective (visibly distinct
        -- and fresh) suggestions. Each retry
        -- re-fires up to n_completions requests in the background (it does not
        -- block the already-shown suggestion), so a higher cap mostly costs
        -- extra requests at low-entropy positions where a distinct second
        -- completion may never exist. Retries stop as soon as the pool reaches
        -- n_completions.
        max_retries = 6,
        -- Context bands for reusing a cached completion as the cursor moves
        -- forward. Because every request snaps its prefix to the same start
        -- byte, a cached entry's prefix is always a prefix of the current
        -- before-cursor text, and the difference (chars typed since that
        -- request) measures how much *less* context the entry carries. Smaller
        -- is fresher.
        --   * <= cache_soft_chars_ahead: fresh -- counts toward the
        --     n_completions bucket we try to keep filled.
        --   * soft..hard: shown and cyclable, but does not count as fresh, so a
        --     background top-up keeps firing to refill the bucket.
        --   * > cache_max_chars_ahead: hidden from the (x/y) cycle list but kept
        --     in cache (a returning cursor re-shows it), except the currently
        --     shown/locked completion, which stays visible regardless so rapid
        --     accept_word / accept_line sliding never drops it.
        cache_soft_chars_ahead = 20,
        cache_max_chars_ahead = 40,
        -- Whether `dismiss` also drops the per-state lock (the completion the
        -- user cycled to / had shown for a buffer state). When true (default),
        -- dismiss is a clean reset: the next visit to that state shows the
        -- naturally ranked completion. Set to false to treat dismiss as a
        -- temporary "get out of my way" hide that keeps the lock, so re-enabling
        -- or re-triggering at the same state brings the chosen completion back.
        dismiss_drops_lock = true,
        -- Preemptive tail prefetch while cycling. When cycling (next) lands
        -- within this many entries of the end of the list, fire a background
        -- fetch (up to max_retries attempts) for a completion not yet in the
        -- list, appending it without moving the user. This means scrolling
        -- further down never blocks on a request. 0 disables it; 1 prefetches
        -- only when at the very last entry.
        prefetch_ahead = 0,
        -- Prefix (before-cursor) size, decoupled from the suffix. By default the
        -- prefix and suffix share a single budget (`context_window`) split by
        -- `context_ratio`, so the prefix is only ever context_window*context_ratio
        -- (e.g. 16000*0.75 = 12000). Set this to size the prefix directly instead:
        -- the prefix gets exactly this many chars and the suffix is sized on its
        -- own by `context_after_chars` (below). So `context_before_chars = 16000`
        -- with `context_after_chars = 4000` gives a 16k prefix + 4k suffix in a
        -- long doc, rather than 12k/4k. While anchored the prefix still grows up
        -- to `context_growth_slack` chars past this. nil keeps the legacy
        -- combined budget. virtualtext (FIM) only; cmp / lsp / blink are
        -- unaffected.
        context_before_chars = nil,
        -- Backward headroom for suffix-stable rewinds, mainly backspace/delete
        -- before the cursor. We pin (fetch and send) this many chars of prefix
        -- BEYOND context_before_chars, so the cursor can rewind up to this far
        -- and still reuse the same warm anchor if the suffix gate still matches.
        -- A jump that changes the suffix still re-pins. The request prefix is
        -- therefore context_before_chars + context_back_slack (e.g. 16000 + 8000
        -- = 24000). Requires context_before_chars; 0 disables backward reuse.
        context_back_slack = 0,
        -- Suffix (after-cursor) char cap for FIM requests, bounded independently
        -- of the prefix. A constant only -- the suffix must stay byte-stable as
        -- you type, because SPM models (Codestral) lead the prompt with the
        -- suffix, so a suffix that resized with the growing prefix would cold-bust
        -- the whole server cache every keystroke. The suffix is otherwise cheap
        -- to keep small: it is rarely the cached part anyway.
        --   nil    -> no extra cap (suffix sized by context_window/ratio)
        --   number -> hard cap of that many chars
        context_after_chars = nil,
        -- Context anchor reuse: how many chars the request prefix is allowed to
        -- grow past the previous fully-warm prefix before we re-anchor ("snap").
        -- The anchor pins the start of the prompt prefix: while you type forward
        -- it stays put and the prompt just grows at the cursor edge, so the
        -- leading tokens are byte-identical request to request and the server's
        -- KV cache stays warm. This is the append budget: freshly typed text or
        -- a paste at the cursor can grow this far before the next snap. 0
        -- disables the feature (legacy behavior: window slides on every
        -- keystroke).
        --
        -- This helps any FIM model and is especially valuable for SPM-ordered
        -- prompts (suffix before prefix), where appending at the cursor edge
        -- doesn't invalidate suffix tokens either. Cached prompt tokens are
        -- also far cheaper than fresh ones, so a long-lived anchor cuts cost.
        --
        -- The anchor only engages when the file is long enough that the
        -- context window truncates the prefix. Files that fit entirely within
        -- `context_window` are always sent fresh (they stay prefix-stable on
        -- their own as you type forward), so short files are unaffected -- and
        -- text inserted above the cursor, like a new title, is never clipped.
        --
        -- Sizing: treat this as part of your context budget. While anchored,
        -- the prompt can exceed `context_window` by up to this many chars, and
        -- each request fetches enough text for the larger of context_growth_slack
        -- and context_divergence_slack. With a small window for a local model
        -- (e.g. 512) scale this down so it doesn't dominate the prompt;
        -- re-anchoring is a single chunked cache miss rather than a per-char one.
        context_growth_slack = 2048,
        -- Cold-tail cap for edits/pastes that change bytes already inside the
        -- anchored prefix. Unlike a pure append, a divergence forces the server
        -- to recompute from the edit point to the cursor, so you may want this
        -- smaller than context_growth_slack. nil keeps the old behavior and uses
        -- context_growth_slack for both append and divergence.
        context_divergence_slack = nil,
    },
    provider = 'codestral',
    -- the maximum total characters of the context before and after the cursor
    -- 16000 characters typically equate to approximately 4,000 tokens for
    -- LLMs.
    context_window = 16000,
    -- when the total characters exceed the context window, the ratio of
    -- context before cursor and after cursor, the larger the ratio the more
    -- context before cursor will be used. This option should be between 0 and
    -- 1, context_ratio = 0.75 means the ratio will be 3:1.
    context_ratio = 0.75,
    throttle = 1000, -- only send the request every x milliseconds, use 0 to disable throttle.
    -- debounce the request in x milliseconds, set to 0 to disable debounce
    debounce = 400,
    -- Control notification display for request status
    -- Notification options:
    -- false: Disable all notifications (use boolean false, not string "false")
    -- "debug": Display all notifications (comprehensive debugging)
    -- "verbose": Display most notifications
    -- "warn": Display warnings and errors only
    -- "error": Display errors only
    notify = 'warn',
    -- The request timeout, measured in seconds. When streaming is enabled
    -- (stream = true), setting a shorter request_timeout allows for faster
    -- retrieval of completion items, albeit potentially incomplete.
    -- Conversely, with streaming disabled (stream = false), a timeout
    -- occurring before the LLM returns results will yield no completion items.
    request_timeout = 3,
    -- Command used to make HTTP requests.
    curl_cmd = 'curl',
    -- Extra arguments passed to curl (list of strings).
    curl_extra_args = {},
    -- Log every request/response as one JSON line (JSONL) for later inspection
    -- with jq. Each record holds the full request body, the raw response, the
    -- curl exit code and elapsed_ms. The Authorization header is never logged,
    -- so API keys stay out. The HTTP runs in a forked curl process, so this
    -- only adds a small synchronous append off the keystroke hot path.
    -- Covers codestral / FIM providers and duet.
    --   false  -> disabled (default)
    --   true   -> stdpath('cache')/minuet/requests.jsonl
    --   string -> that file path
    request_log = false,
    -- Numbers-only accounting log for :Minuet stats, one JSON line per finished
    -- FIM request: model, prompt/completion/cached token counts, latency, ts.
    -- Unlike request_log this NEVER contains request/response bodies (no source
    -- code), so it is safe to keep on by default; it persists the dashboard's
    -- token/cache data so it survives restarts and is greppable with jq.
    --   true   -> stdpath('cache')/minuet/stats.jsonl (default)
    --   string -> that file path
    --   false  -> disabled
    stats_log = true,
    -- If completion item has multiple lines, create another completion item
    -- only containing its first line. This option only has impact for cmp and
    -- blink. For virtualtext, no single line entry will be added.
    add_single_line_entry = true,
    -- The number of completion items encoded as part of the prompt for the
    -- chat LLM. For FIM model, this is the number of requests to send. It's
    -- important to note that when 'add_single_line_entry' is set to true, the
    -- actual number of returned items may exceed this value. Additionally, the
    -- chat LLM cannot guarantee the exact number of completion items
    -- specified, as this parameter serves only as a prompt guideline.
    n_completions = 3,
    -- FIM only. When several requests run in parallel (n_completions > 1) we
    -- bias the shown suggestion toward the request sent first, rather than
    -- whichever streams back first (the first to finish tends to be the
    -- shortest). If a later-sent request settles before request #1, we wait up
    -- to this many milliseconds for #1 before painting the later one. Set to 0
    -- to paint as soon as anything arrives.
    first_request_grace_ms = 100,
    --  Length of context after cursor used to filter completion text.
    --
    -- This setting helps prevent the language model from generating redundant
    -- text.  When filtering completions, the system compares the suffix of a
    -- completion candidate with the text immediately following the cursor.
    --
    -- If the length of the longest common substring between the end of the
    -- candidate and the beginning of the post-cursor context exceeds this
    -- value, that common portion is trimmed from the candidate.
    --
    -- For example, if the value is 15, and a completion candidate ends with a
    -- 20-character string that exactly matches the 20 characters following the
    -- cursor, the candidate will be truncated by those 20 characters before
    -- being delivered.
    after_cursor_filter_length = 15,
    -- Similar to after_cursor_filter_length but trim the completion item from
    -- prefix instead of suffix.
    before_cursor_filter_length = 2,
    -- Whether to apply context-sequence filtering to FIM completions. The
    -- filter removes text that mirrors the surrounding context, which can strip
    -- legitimate indentation and leading/trailing content from FIM models.
    -- Disabled by default for FIM providers; enable only if the model
    -- consistently repeats context verbatim.
    fim_filter_context = false,
    -- Codestral-only FIM fix. Codestral reflexively prepends a spurious leading
    -- newline to its completion when the cursor sits at the start of a fresh
    -- line (the prefix ends in a newline) and the suffix is empty or only
    -- newlines: with no right-context it re-emits a line break that is already
    -- there, inserting a blank line. When true (default), in that window we (1)
    -- strip the one spurious leading newline from the response, and (2) widen a
    -- '\n' stop sequence to '\n\n' for the request, since the spurious newline
    -- would otherwise trip a '\n' stop immediately and return nothing. Applies
    -- to the codestral provider on FIM only; set false to disable. See
    -- scripts/probe_codestral_*newline*.py for the analysis.
    codestral_strip_spurious_newline = true,
    proxy = nil,
}

M.default_system = {
    template = default_system_template,
    prompt = default_prompt,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_system_prefix_first = {
    template = default_system_template,
    prompt = default_prompt_prefix_first,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_chat_input = default_chat_input
M.default_chat_input_prefix_first = default_chat_input_prefix_first

M.default_few_shots = default_few_shots
M.default_few_shots_prefix_first = default_few_shots_prefix_first

--- Configuration for FIM template
---@class minuet.FIMTemplate
---@field prompt minuet.FIMTemplateFunction
---@field suffix minuet.FIMTemplateFunction | boolean

---@type minuet.FIMTemplate
M.default_fim_template = {
    prompt = default_fim_prompt,
    suffix = default_fim_suffix,
}

M.provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil, -- the identifier to stop the completion generation
            max_tokens = nil,
            -- Routing hint that pins consecutive FIM requests to the same warm
            -- prompt-cache replica (Mistral/OpenAI field, merged verbatim into
            -- the request body). Paired with a stable suffix and anchored prefix
            -- (see virtualtext.context_growth_slack) it turns Codestral's
            -- per-keystroke recompute into near-full prompt cache reuse;
            -- without it ~43% of requests get load-balanced onto a cold
            -- replica and recompute the whole prompt. A single shared value is
            -- fine: caching is isolated per API key, and a shared key showed no
            -- latency cost and no eviction of unrelated contexts in testing.
            -- Set nil to disable. Provider-specific -- only send to endpoints
            -- that accept this field.
            prompt_cache_key = 'minuet-codestral',
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {},
    },
    openai = {
        model = 'gpt-5.4-nano',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = M.default_system_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    claude = {
        max_tokens = 256,
        api_key = 'ANTHROPIC_API_KEY',
        model = 'claude-haiku-4-5',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        stream = true,
        optional = {
            stop_sequences = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    openai_compatible = {
        model = 'deepseek/deepseek-v4-flash',
        system = M.default_system_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        api_key = 'OPENROUTER_API_KEY',
        name = 'Openrouter',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    gemini = {
        model = 'gemini-2.0-flash',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = M.default_system_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        stream = true,
        optional = {},
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    openai_fim_compatible = {
        model = 'deepseek-v4-flash',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {},
    },
}

M.duet = require 'minuet.duet.config'

M.presets = {}

-- **List** of functions to execute. If any function returns `false`, Minuet
-- will not trigger auto-completion. Manual completion can still be invoked,
-- even if these functions evaluate to `false`, when using `nvim-cmp`,
-- `blink-cmp`, or virtual text (excluding LSP).
-- When this list is empty (the default), it always evaluates to `true`.
-- Note that this is called each time Minuet attempts to trigger
-- auto-completion, so ensure the functions in this list are highly efficient.
---@type (fun(): boolean)[]
M.enable_predicates = {}

return M
