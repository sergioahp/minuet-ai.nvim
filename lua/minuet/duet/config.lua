local default_markers = {
    editable_region_start = '<editable_region>',
    editable_region_end = '</editable_region>',
    cursor_position = '<cursor_position/>',
}
local function get_markers()
    local markers = default_markers
    if require('minuet').config then
        markers = require('minuet').config.duet.markers
    end
    return markers
end

local function render_markers(template)
    local shared_utils = require 'minuet.utils'

    local markers = get_markers()
    template =
        shared_utils.replace_string_literal(template, '{{{editable_region_start}}}', markers.editable_region_start)
    template = shared_utils.replace_string_literal(template, '{{{editable_region_end}}}', markers.editable_region_end)
    template = shared_utils.replace_string_literal(template, '{{{cursor_position}}}', markers.cursor_position)

    return template
end

local function make_default_prompt()
    return render_markers [[You are an AI editing engine that rewrites only the editable region in a document.

Input markers:
- `{{{editable_region_start}}}` and `{{{editable_region_end}}}` wrap the editable region.
- `{{{cursor_position}}}` marks the current cursor position inside that editable region.]]
end

local function make_default_guidelines()
    return render_markers [[Guidelines:
1. Return only the rewritten editable region, wrapped in `{{{editable_region_start}}}` and `{{{editable_region_end}}}`.
2. Include exactly one `{{{cursor_position}}}` marker inside the rewritten editable region.
3. Preserve indentation, formatting, blank lines, and surrounding syntax conventions. Keep the exact number of empty lines unless you are intentionally changing them.
4. For any text or code inside the editable region that is not intended to change, copy it verbatim. Do not paraphrase, refactor, reformat, or otherwise alter unchanged content.
5. Make only the smallest changes necessary to satisfy the requested edit.
6. Do not return explanations, markdown fences, or any content outside the editable region block.
7. Make the rewrite coherent with the surrounding non-editable text.]]
end

local default_system = {
    template = '{{{prompt}}}\n{{{guidelines}}}',
    prompt = make_default_prompt,
    guidelines = make_default_guidelines,
}

local function get_context_value(key)
    return function(context)
        return context[key] or ''
    end
end

---@type minuet.DuetChatInput
local default_chat_input = {
    template = function()
        return render_markers [[{{{non_editable_region_before}}}
{{{editable_region_start}}}
{{{editable_region_before_cursor}}}{{{cursor_position}}}{{{editable_region_after_cursor}}}
{{{editable_region_end}}}
{{{non_editable_region_after}}}]]
    end,
    non_editable_region_before = get_context_value 'non_editable_region_before',
    editable_region_before_cursor = get_context_value 'editable_region_before_cursor',
    editable_region_after_cursor = get_context_value 'editable_region_after_cursor',
    non_editable_region_after = get_context_value 'non_editable_region_after',
}

local default_few_shots = function()
    return {
        {
            role = 'user',
            content = render_markers [[type User = {
    id: string;
    name: string;
    role?: string;
    active?: boolean;
};

async function buildRequest(user: User, overrides: Record<string, any> = {}) {
    const baseHeaders = { 'content-type': 'application/json' };

{{{editable_region_start}}}
    const payload = {
        id: user.id,
        name: user.name,
    };

    return {
        method: 'POST',
        headers: baseHeaders,
        body: JSON.stringify(payload{{{cursor_position}}}),
    };
{{{editable_region_end}}}
}

export async function sendUser(user: User, overrides = {}) {
    const request = await buildRequest(user, overrides);
    return fetch('/api/users', request);
}]],
        },
        {
            role = 'assistant',
            content = render_markers [[{{{editable_region_start}}}
    const payload = {
        id: user.id,
        name: user.name,
        role: overrides.role ?? user.role ?? "viewer",
        active: overrides.active ?? user.active ?? true,
    };

    return {
        method: 'POST',
        headers: {
            ...baseHeaders,
            ...overrides.headers,
        },
        body: JSON.stringify(payload),
        signal: overrides.signal,
        keepalive: overrides.keepalive ?? false,{{{cursor_position}}}
    };
{{{editable_region_end}}}]],
        },
    }
end

local function make_openai_options()
    return {
        model = 'gpt-5.4-mini',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

local function make_claude_options()
    return {
        model = 'claude-haiku-4-5',
        api_key = 'ANTHROPIC_API_KEY',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        max_tokens = 8192,
        optional = {},
        transform = {},
    }
end

local function make_gemini_options()
    return {
        model = 'gemini-3-flash-preview',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

local function make_openai_compatible_options()
    return {
        model = 'openai/gpt-oss-120b',
        api_key = 'OPENROUTER_API_KEY',
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        name = 'Openrouter',
        system = vim.deepcopy(default_system),
        few_shots = default_few_shots,
        chat_input = vim.deepcopy(default_chat_input),
        optional = {
            -- NES trades a little latency for reasoning quality: `effort = 'medium'`
            -- (low reverts/stalls on harder multi-step edits like a tableau pivot).
            -- Pin Cerebras then Groq and disallow other (slower) providers.
            reasoning = { effort = 'medium' },
            provider = { order = { 'cerebras', 'groq' }, allow_fallbacks = false },
        },
        transform = {},
    }
end

local function make_inception_edit_options()
    return {
        model = 'mercury-edit-2',
        api_key = 'INCEPTION_API_KEY',
        end_point = 'https://api.inceptionlabs.ai/v1/edit/completions',
        name = 'Inception Mercury Edit 2',
        -- Editable region: Inception recommends a small cursor-centered window
        -- ([cursor-5, cursor+10], ~100-150 tokens) since it dominates output
        -- latency, with ~25 lines a practical upper bound. The region snaps out
        -- to enclosing syntax nodes while it fits in max_editable_lines; nearby
        -- file context is present outside the code_to_edit tags.
        lines_before = 5,
        lines_after = 10,
        max_editable_lines = 25,
        -- Complete tagged prompt budget in bytes, not model tokens.
        max_prompt_bytes = 32000,
        -- recently_viewed_code_snippets: up to snippet_count cross-file excerpts
        -- of ~snippet_radius*2 lines around recent cursor rows, plus diagnostics
        -- and treesitter scope (max_siblings sibling signatures).
        snippet_count = 3,
        snippet_radius = 10,
        max_siblings = 4,
        max_tokens = 1000,
        optional = {},
    }
end

-- NES (apply_patch) session prompt. The model receives the user's recent edits
-- (apply_patch dialect), the current file, and the cursor position as a SEPARATE
-- note (kept out of the file/patch text, which is the in-distribution apply_patch
-- content the model handles well). It predicts the single next edit.
--
-- Prompt tuned against gpt-oss-120b: at reasoning effort `low`, and with a vaguer
-- "most likely next edit" instruction, the model reverts recent edits or stalls;
-- spelling out the two intents (finish-at-cursor vs continue-a-multi-site-change),
-- the exact-match requirement, and "never revert" makes apply_patch land reliably.
local function make_nes_system()
    return [[You are a next-edit-prediction engine inside the user's code editor.

You are given the user's recent edits (in apply_patch dialect, oldest to newest),
the current file, and—separately—the cursor position. Predict the user's SINGLE
next edit and emit it by calling the `apply_patch` tool.

The next edit is usually one of:
- finishing or fixing the edit in progress AT the cursor, or
- the next site of a repetitive change the user is making across the file (such as
  a rename), which is frequently on a DIFFERENT line. Infer the change from the
  recent edits and apply it to the next not-yet-changed occurrence.

Rules:
- Emit exactly ONE small `*** Update File` hunk. No `*** Add File`, `*** Delete
  File`, or `*** Move to`.
- Be decisive: even a SINGLE recent edit can be the start of a repeated change.
  If it looks repeatable and other matching sites remain, propose the next one
  now rather than waiting for more examples.
- Match the user's edit granularity. If recent edits change one literal/token at
  a time, predict one literal/token change next; do not expand that workflow into
  a whole-line or whole-block rewrite just because a larger transformation is
  inferable.
- The patch must apply to the CURRENT file: context and removed (`-`) lines must
  match the buffer EXACTLY. You already have the full current file above, so emit
  the patch directly; only call `read` to re-check the exact text if a patch you
  tried this turn failed to apply.
- Your patch is applied at the occurrence NEAREST the cursor, so you do not need
  to uniquely locate the edit or count lines. Emit the SMALLEST hunk that names
  the change — usually a bare `@@` and just the one changed line as `-`/`+`. Do
  NOT enumerate or count the file's lines, and do NOT call `read` merely to find a
  line number: you already have the full file and the cursor note.
- The cursor position is given to you separately as a note; never put a cursor
  marker or annotation inside a patch.
- Never revert or undo a recent edit, and never emit a no-op patch.

Whether you may decline to propose an edit depends on how this prediction was
triggered; that final instruction is given at the end of this system prompt.]]
end
local DUET_NO_EDIT_TOKEN = '*** No Edit'

-- Whether declining (the no-edit token) is allowed depends on the trigger and is
-- appended to the system prompt per prediction (see init.build_messages):
--   auto-trigger fires on its own, so the model may legitimately decline;
--   a manual trigger is an explicit user request, so it MUST produce an edit.
local function make_auto_instruction(no_edit_token)
    return 'This prediction was auto-triggered. If no edit is warranted, reply with the text `'
        .. no_edit_token
        .. '` and do not call a tool.'
end
local function make_manual_instruction(no_edit_token)
    return 'This prediction was explicitly requested by the user, so you MUST propose a concrete next '
        .. 'edit: emit exactly one apply_patch hunk. Declining with `'
        .. no_edit_token
        .. '` is not allowed here.'
end

---@alias minuet.DuetChatInputFunction fun(context: table): string

--- Configuration for formatting duet chat input to the LLM
---@class minuet.DuetChatInput
---@field template string|fun(): string Template string with placeholders for context parts
---@field non_editable_region_before string|minuet.DuetChatInputFunction
---@field editable_region_before_cursor string|minuet.DuetChatInputFunction
---@field editable_region_after_cursor string|minuet.DuetChatInputFunction
---@field non_editable_region_after string|minuet.DuetChatInputFunction

---@class minuet.DuetEditableRegion
---@field lines_before integer
---@field lines_after integer
---@field before_region_filter_length integer
---@field after_region_filter_length integer

---@class minuet.DuetNonEditableRegion
---@field context_window integer
---@field context_ratio number

---@class minuet.DuetConfig
---@field provider string
---@field request_timeout integer
---@field editable_region minuet.DuetEditableRegion
---@field non_editable_region minuet.DuetNonEditableRegion
---@field markers { editable_region_start: string, editable_region_end: string, cursor_position: string }
---@field preview { mode: string, cursor: string, marker: string, block_chunk_size: integer, inline_max_groups: integer, inline_max_edit_ratio: number, line_pair_min_similarity: number, ts_highlight: boolean, ts_dim: boolean, ts_blend: integer, ts_add_bg: integer }
---@field provider_options table<string, table>
local M = {
    -- NES (apply_patch) is the active duet design; default to gpt-oss via OpenRouter.
    provider = 'openai_compatible',
    request_timeout = 15,
    editable_region = {
        lines_before = 8,
        lines_after = 15,
        before_region_filter_length = 30,
        after_region_filter_length = 30,
    },
    non_editable_region = {
        context_window = 40000,
        context_ratio = 0.75,
    },
    markers = vim.deepcopy(default_markers),
    preview = {
        mode = 'inline',
        cursor = '\u{f246}',
        marker = ' ',
        block_chunk_size = 10,
        inline_max_groups = 2,
        inline_max_edit_ratio = 0.9,
        line_pair_min_similarity = 0.35,
        -- Treesitter foreground coloring of proposed (added) text. Off by
        -- default. When on, proposed blocks and inline edit fragments render
        -- with (dimmed) syntax colors over a subtle "added" background tint
        -- instead of the flat add color. Inline fragments are colored in the
        -- context of their full proposed line, so a word changed inside a
        -- string still reads as @string. See lua/minuet/duet/ts_highlight.lua.
        ts_highlight = false,
        ts_dim = true,
        ts_blend = 35,
        ts_add_bg = 0x294b38,
    },
    -- NES session settings (apply_patch flow). See duet-nes-spec.md.
    session = {
        no_edit_token = DUET_NO_EDIT_TOKEN,
        system = make_nes_system(),
        -- Mode-specific trailing instruction (auto may decline, manual must not).
        auto_instruction = make_auto_instruction(DUET_NO_EDIT_TOKEN),
        manual_instruction = make_manual_instruction(DUET_NO_EDIT_TOKEN),
        capability_reminder = 'Reminder: emit exactly one small `*** Update File` hunk via the apply_patch '
            .. 'tool; no Add/Delete/Move; context and `-` lines must match the current buffer exactly; '
            .. 'the cursor is provided as a separate note—never put a cursor marker in a patch.',
        history_context_lines = 8,
        max_edits = 20,
        idle_minutes = 20,
        seed_edits = 3,
        capability_reminder_every = 5,
        max_attempts = 3,
        max_reads = 2,
        -- Number of recent prediction requests kept for `:Minuet duet inspect`
        -- / <leader>M. Mercury Edit is not chat-shaped, so each request stores
        -- its full prompt and raw response here for side-by-side inspection.
        inspect_history_max = 12,
        -- Inter-diff memory: optionally replay this session's earlier predictions
        -- (the model's own patch + what the user did with it) as interleaved turns
        -- BEFORE the full current file. Additive — never replaces the file.
        prediction_memory = false,
        prediction_memory_max = 8,
        memory_preamble = 'Your earlier next-edit predictions this session (oldest first), each '
            .. 'followed by what the user did with it:',
        auto_trigger = false,
        -- Safety valve for auto-triggered next-edit requests. Manual requests
        -- bypass this; 0 disables the limit. Edit capture itself is immediate.
        max_auto_requests_per_second = 10,
        prefetch_after_preview = true,
        diagnostic_auto_trigger = true,
        diagnostic_history_max = 20,
        partial_accept_level = 4,
        -- Mercury edit_diff_history is an append-only deque: keep the last N
        -- uncoalesced edits, including model predictions the user accepted.
        edit_history_max_entries = 20,
        -- How each edit_diff_history entry is rendered for the inception_edit
        -- (Mercury Edit 2) prompt. A/B knob — neither is strictly better:
        --   'synthetic' (default, original): a compact `@@ -1,N +1,M @@` block
        --       with blank lines stripped. Aggressive — strongest at propagating
        --       a repeated edit to the next site, but on a plain deletion the
        --       model tends to re-insert (un-delete) the line you just removed.
        --   'unified': a faithful unified diff with real line numbers + context.
        --       Conservative — far fewer un-deletes, but slightly weaker at
        --       continuing a multi-site change (more frequent no-ops).
        edit_history_format = 'synthetic',
    },
    provider_options = {
        openai = make_openai_options(),
        claude = make_claude_options(),
        gemini = make_gemini_options(),
        openai_compatible = make_openai_compatible_options(),
        inception_edit = make_inception_edit_options(),
    },
}

return M
