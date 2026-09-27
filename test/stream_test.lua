--- Проверки сжатия и разжатия: строкой, потоком, пределы и уступки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local compress = helper.compress
local CHUNK = helper.stream.CHUNK --[[@as integer]]

local g = t.group('tnt.compress.stream')

g.after_each(helper.restore)

--- Строки выгрузки, на которых различимы все параметры сжатия.
local ROWS = helper.rows(3000)

--- Параметры, которыми сжимает пакет по умолчанию: шестой уровень,
--- окно 32 КБ с обёрткой gzip, память 8, стратегия по умолчанию.
local DEFAULTS = { level = 6, window = 31, memory = 8, strategy = 0 }

--- Те же параметры с одной правкой.
---@param changes table
---@return table
local function defaults_with(changes)
    local settings = table.copy(DEFAULTS)

    for name, value in pairs(changes) do
        settings[name] = value
    end

    return settings
end

g.test_the_package_compresses_exactly_as_zlib_with_its_defaults = function()
    local packed = compress.deflate(ROWS)

    t.assert_equals(packed, helper.reference(ROWS, DEFAULTS))

    -- Соседние значения каждого параметра дают другой выход: сверка выше
    -- различает их, а не проходит на любых.
    for _, changes in ipairs({
        { level = 5 },
        { level = 7 },
        { window = 30 },
        { memory = 7 },
        { memory = 9 },
        { strategy = 1 },
    }) do
        t.assert_not_equals(helper.reference(ROWS, defaults_with(changes)), packed)
    end
end

g.test_each_format_has_its_own_wrapper = function()
    t.assert_equals(compress.FORMATS, { 'gzip', 'zlib', 'raw' })

    t.assert_equals(compress.deflate(ROWS, { format = 'gzip' }), helper.reference(ROWS, DEFAULTS))
    t.assert_equals(compress.deflate(ROWS, { format = 'zlib' }), helper.reference(ROWS, defaults_with({ window = 15 })))
    t.assert_equals(compress.deflate(ROWS, { format = 'raw' }), helper.reference(ROWS, defaults_with({ window = -15 })))

    -- gzip начинается магией 1f 8b, zlib — байтом 78.
    t.assert_equals({ compress.deflate('a'):byte(1, 2) }, { 0x1f, 0x8b })
    t.assert_equals(compress.deflate('a', { format = 'zlib' }):byte(1), 0x78)
end

g.test_the_level_is_the_zlib_level = function()
    t.assert_equals(compress.LEVEL, 6)

    for _, level in ipairs({ 1, 9 }) do
        t.assert_equals(
            compress.deflate(ROWS, { level = level }),
            helper.reference(ROWS, defaults_with({ level = level })),
            level
        )
    end

    -- Нулевой — без сжатия: блоки хранения, и выход длиннее входа. Границы
    -- таких блоков zlib ставит по нарезке входа, так что с оракулом,
    -- сжимавшим одним вызовом, байт в байт он не сходится.
    local stored = compress.deflate(ROWS, { level = 0 })

    t.assert_gt(#stored, #ROWS)
    t.assert_equals(compress.inflate(stored), ROWS)
end

g.test_every_format_comes_back = function()
    for _, format in ipairs(compress.FORMATS) do
        local packed = compress.deflate(ROWS, { format = format })

        t.assert_equals(compress.inflate(packed, { format = format }), ROWS, format)
    end

    t.assert_equals(compress.inflate(compress.deflate('')), '')
end

g.test_a_foreign_format_is_refused = function()
    local packed = compress.deflate('привет', { format = 'zlib' })
    local text, err = compress.inflate(packed)

    t.assert_equals(text, nil)
    t.assert_equals(err.kind, compress.CORRUPT)
    t.assert_equals(tostring(err), 'сжатые данные испорчены: incorrect header check')
end

g.test_gzip_members_follow_one_another = function()
    local first = compress.deflate('первый ')
    local second = compress.deflate('второй')

    -- Как `cat a.gz b.gz`: файл, в который дописывали, читается целиком.
    t.assert_equals(compress.inflate(first .. second), 'первый второй')

    -- И так же, когда член кончается ровно на границе куска.
    local inflater = compress.inflater()

    t.assert_equals(inflater:write(first), 'первый ')
    t.assert_equals(inflater:write(second), 'второй')
    t.assert_equals(inflater:finish(), true)

    -- Следующий член разжимается заново с начала: оборванный — оборван,
    -- а больший буфера разжимается несколькими вызовами без сброса.
    t.assert_equals(select(2, compress.inflate(first .. second:sub(1, -2))).kind, compress.TRUNCATED)
    t.assert_equals(compress.inflate(first .. compress.deflate(ROWS)), 'первый ' .. ROWS)
end

g.test_bytes_after_the_end_are_refused_outside_gzip = function()
    for _, format in ipairs({ 'zlib', 'raw' }) do
        local packed = compress.deflate('данные', { format = format })
        local text, err = compress.inflate(packed .. 'x', { format = format })

        t.assert_equals(text, nil, format)
        t.assert_equals(err.kind, compress.CORRUPT, format)
        t.assert_equals(
            err.message,
            'сжатые данные испорчены: лишние байты после конца потока',
            format
        )

        -- Лишнее, пришедшее следующим куском, — то же.
        local inflater = compress.inflater({ format = format })

        t.assert_equals(inflater:write(packed), 'данные', format)
        t.assert_equals({ inflater:write('x') }, { nil, err }, format)
    end

    -- У gzip лишнее читается следующим членом и отвергается его заголовком.
    local _, err = compress.inflate(compress.deflate('данные') .. 'мусор')

    t.assert_equals(err.message, 'сжатые данные испорчены: incorrect header check')
end

g.test_a_cut_stream_is_truncated = function()
    local packed = compress.deflate(ROWS)

    for _, input in ipairs({ packed:sub(1, -2), packed:sub(1, 10), '' }) do
        local text, err = compress.inflate(input)

        t.assert_equals(text, nil)
        t.assert_equals(err.kind, compress.TRUNCATED)
        t.assert_equals(
            err.message,
            'сжатые данные оборваны: вход кончился раньше конца потока'
        )
    end
end

g.test_a_stream_asking_for_a_dictionary_is_corrupt = function()
    -- Заголовок zlib с флагом словаря: 78 20 и номер словаря. У zlib на это
    -- нет текста, и отказ называет код.
    local text, err = compress.inflate('\x78\x20\0\0\0\1', { format = 'zlib' })

    t.assert_equals(text, nil)
    t.assert_equals(err.kind, compress.CORRUPT)
    t.assert_equals(err.message, 'сжатые данные испорчены: код zlib 2')
end

g.test_the_limit_counts_the_output = function()
    t.assert_equals(compress.LIMIT, 16 * 1024 * 1024)

    local packed = compress.deflate(ROWS)

    t.assert_equals(compress.inflate(packed, { limit = #ROWS }), ROWS)

    local text, err = compress.inflate(packed, { limit = #ROWS - 1 })

    t.assert_equals(text, nil)
    t.assert_equals(err.kind, compress.TOO_LARGE)
    t.assert_equals(err.message, ('разжатое больше предела в %d байт'):format(#ROWS - 1))

    -- Поток считает разжатое всех кусков вместе.
    local inflater = compress.inflater({ limit = 10 })
    local stream = compress.deflater()
    local head = stream:flush('123456')

    t.assert_equals(inflater:write(head), '123456')
    t.assert_equals(select(2, inflater:write(stream:finish('78901'))).kind, compress.TOO_LARGE)
end

g.test_the_default_limit_stops_a_bomb = function()
    local bomb = compress.deflate(string.rep('\0', compress.LIMIT + 1))

    t.assert_equals(select(2, compress.inflate(bomb)).kind, compress.TOO_LARGE)
    t.assert_equals(#compress.inflate(compress.deflate(string.rep('\0', compress.LIMIT))), compress.LIMIT)
end

g.test_a_deflater_gives_the_whole_stream_by_pieces = function()
    local deflater = compress.deflater({ format = 'zlib', level = 9 })
    local parts = {
        deflater:write('abc'),
        deflater:write(''),
        deflater:flush(),
        deflater:flush('def'),
        deflater:finish('ghi'),
    }

    t.assert_equals(compress.inflate(table.concat(parts), { format = 'zlib' }), 'abcdefghi')

    -- Без куска `finish` только заканчивает поток.
    local plain = compress.deflater()

    t.assert_equals(compress.inflate(plain:write('xyz') .. plain:finish()), 'xyz')
end

g.test_a_flush_keeps_the_history_of_the_stream = function()
    -- Сброс — `Z_SYNC_FLUSH`: выход выравнивается на байт, а словарь
    -- остаётся, и повтор после сброса сжимается ссылкой назад. `Z_FULL_FLUSH`
    -- на первом сбросе дал бы те же байты и разошёлся бы только на втором.
    local deflater = compress.deflater()
    local packed = deflater:flush(ROWS) .. deflater:flush(ROWS) .. deflater:finish()

    t.assert_equals(packed, helper.replay(DEFAULTS, { { ROWS, 2 }, { ROWS, 2 }, { '', 4 } }))
end

g.test_a_flush_makes_everything_so_far_readable = function()
    local deflater = compress.deflater()
    local inflater = compress.inflater()

    t.assert_equals(
        inflater:write(deflater:write('первая ') .. deflater:flush('строка\n')),
        'первая строка\n'
    )
    t.assert_equals(inflater:write(deflater:flush('вторая')), 'вторая')
    t.assert_equals(inflater:write(deflater:finish()), '')
    t.assert_equals(inflater:finish(), true)
end

g.test_an_inflater_takes_the_stream_byte_by_byte = function()
    local packed = compress.deflate('поток по байту')
    local inflater = compress.inflater()
    local parts = {}

    for index = 1, #packed do
        table.insert(parts, inflater:write(packed:sub(index, index)))
    end

    t.assert_equals(table.concat(parts), 'поток по байту')
    t.assert_equals(inflater:finish(), true)
end

g.test_a_full_output_buffer_waiting_for_more_input_is_not_a_failure = function()
    -- Кусок, разжимающийся ровно в буфер: второй вызов zlib не может
    -- продвинуться и отвечает Z_BUF_ERROR — это ожидание входа, не отказ.
    local deflater = compress.deflater()
    local inflater = compress.inflater()
    local body = string.rep('b', CHUNK)

    t.assert_equals(inflater:write(deflater:flush(body)), body)
    t.assert_equals(inflater:write(deflater:finish('tail')), 'tail')
    t.assert_equals(inflater:finish(), true)
end

g.test_an_unfinished_inflater_is_truncated = function()
    local inflater = compress.inflater()

    inflater:write(compress.deflate(ROWS):sub(1, 100))

    local ended, err = inflater:finish()

    t.assert_equals(ended, nil)
    t.assert_equals(err.kind, compress.TRUNCATED)
end

g.test_a_failed_inflater_keeps_its_failure = function()
    local inflater = compress.inflater()
    local text, err = inflater:write('не gzip')

    t.assert_equals(text, nil)
    t.assert_equals(err.kind, compress.CORRUPT)

    -- Следующий кусок — даже годный — получает тот же отказ.
    t.assert_equals({ inflater:write(compress.deflate('годный')) }, { nil, err })
    t.assert_equals({ inflater:finish() }, { nil, err })
end

g.test_a_memory_failure_of_zlib_is_failed = function()
    helper.library({
        tnt_compress_inflate = function()
            return -4
        end,
    })

    local text, err = compress.inflate(compress.deflate('данные'))

    t.assert_equals(text, nil)
    t.assert_equals(err.kind, compress.FAILED)
    t.assert_equals(err.message, 'zlib отказала: не хватило памяти')
end

g.test_a_stream_zlib_cannot_open_is_thrown = function()
    helper.library({
        tnt_compress_deflate_init = function()
            return -4
        end,
        tnt_compress_inflate_init = function()
            return -2
        end,
    })

    helper.assert_blamed({
        {
            function()
                compress.deflate('данные')
            end,
            'zlib не завела поток: код -4',
        },
        {
            function()
                compress.deflater()
            end,
            'zlib не завела поток: код -4',
        },
        {
            function()
                compress.inflate('данные')
            end,
            'zlib не завела поток: код -2',
        },
        {
            function()
                compress.inflater()
            end,
            'zlib не завела поток: код -2',
        },
    })
end

g.test_a_node_without_zlib_throws_at_the_caller = function()
    helper.compress._set_source({
        load = function(name)
            error('нет ' .. name, 0)
        end,
    })

    local missing = 'нет системной библиотеки zlib: нет z; нет libz.so.1'

    helper.assert_blamed({
        {
            function()
                compress.deflate('данные')
            end,
            missing,
        },
        {
            function()
                compress.inflater()
            end,
            missing,
        },
    })
end

g.test_the_work_yields_between_calls_of_zlib = function()
    t.assert_equals(CHUNK, 65536)

    -- Вход уходит кусками по CHUNK: уступка перед каждым следующим.
    for _, case in ipairs({
        { size = CHUNK, yields = 0 },
        { size = CHUNK + 1, yields = 1 },
        { size = 2 * CHUNK + 1, yields = 2 },
    }) do
        local seen = helper.yields()

        compress.deflate(string.rep('a', case.size))

        t.assert_equals(seen.count, case.yields, case.size)
    end

    -- Выход собирается в буфер CHUNK: уступка после каждого полного.
    for _, case in ipairs({
        { size = CHUNK - 1, yields = 0 },
        { size = CHUNK, yields = 1 },
        { size = 3 * CHUNK + 1, yields = 3 },
    }) do
        local packed = compress.deflate(string.rep('a', case.size))
        local seen = helper.yields()

        t.assert_equals(#compress.inflate(packed), case.size)
        t.assert_equals(seen.count, case.yields, case.size)
    end

    -- Несжимаемое заполняет буфер выхода и при сжатии: последний кусок
    -- с накопленным до него не помещается в один буфер.
    local noise = helper.noise(2 * CHUNK)
    local seen = helper.yields()
    local packed = compress.deflate(noise)

    t.assert_equals(seen.count, 2)
    t.assert_gt(#packed, CHUNK + CHUNK / 4)
    t.assert_equals(compress.inflate(packed), noise)
end

g.test_inside_a_transaction_the_work_does_not_yield = function()
    local seen = helper.yields(function()
        return true
    end)
    local body = string.rep('a', 4 * CHUNK)

    t.assert_equals(compress.inflate(compress.deflate(body)), body)
    t.assert_equals(seen.count, 0)
end

g.test_the_real_yield_lets_neighbours_run = function()
    -- Настоящие средства: до `box.cfg` транзакции нет, и работа уступает.
    local fiber = require('fiber')
    local ticks = 0
    local stopped = false

    fiber.new(function()
        while not stopped do
            ticks = ticks + 1
            fiber.yield()
        end
    end)

    compress.deflate(string.rep('a', 4 * CHUNK))
    stopped = true

    -- Уступок три, между четырьмя кусками; под luatest сосед иногда
    -- получает и лишний ход — от уступок самого прогона.
    t.assert_ge(ticks, 3)
end

g.test_a_finished_stream_refuses_out_loud = function()
    local deflater = compress.deflater()
    local inflater = compress.inflater()

    deflater:finish()
    inflater:write(compress.deflate('a'))
    inflater:finish()

    local deflated = 'поток сжатия закончен: finish уже позван'
    local inflated = 'поток разжатия закончен: finish уже позван'

    helper.assert_blamed({
        {
            function()
                deflater:write('a')
            end,
            deflated,
        },
        {
            function()
                deflater:flush()
            end,
            deflated,
        },
        {
            function()
                deflater:finish()
            end,
            deflated,
        },
        {
            function()
                inflater:write('a')
            end,
            inflated,
        },
        {
            function()
                inflater:finish()
            end,
            inflated,
        },
    })
end

g.test_bad_arguments_blame_the_caller = function()
    local deflater = compress.deflater()
    local inflater = compress.inflater()

    helper.assert_blamed({
        {
            function()
                compress.deflate(helper.wrong(5))
            end,
            'данные — строка, а не число',
        },
        {
            function()
                compress.inflate(helper.wrong(nil))
            end,
            'данные — строка, а не nil',
        },
        {
            function()
                compress.deflate('a', helper.wrong('gzip'))
            end,
            'настройки — таблица, а не строка',
        },
        {
            function()
                compress.deflate('a', helper.wrong({ fromat = 'gzip' }))
            end,
            'настройки: ключа «fromat» нет, есть format, level',
        },
        {
            function()
                compress.deflate('a', { format = 'zip' })
            end,
            'настройки.format — одно из «gzip», «zlib», «raw», а не «zip»',
        },
        {
            function()
                compress.deflater({ level = 10 })
            end,
            'настройки.level — число от 0 до 9, а не 10',
        },
        {
            function()
                compress.deflater({ level = -1 })
            end,
            'настройки.level — число от 0 до 9, а не -1',
        },
        {
            function()
                compress.deflate('a', { level = 1.5 })
            end,
            'настройки.level — целое число, а не 1.5',
        },
        {
            function()
                compress.inflate('a', helper.wrong({ level = 1 }))
            end,
            'настройки: ключа «level» нет, есть format, limit',
        },
        {
            function()
                compress.inflater({ format = 'deflate' })
            end,
            'настройки.format — одно из «gzip», «zlib», «raw», а не «deflate»',
        },
        {
            function()
                compress.inflate('a', { limit = 0 })
            end,
            'настройки.limit — число больше 0, а не 0',
        },
        {
            function()
                compress.inflater({ limit = helper.wrong('много') })
            end,
            'настройки.limit — число, а не строка',
        },
        {
            function()
                deflater:write(helper.wrong(1))
            end,
            'кусок — строка, а не число',
        },
        {
            function()
                deflater:flush(helper.wrong(true))
            end,
            'кусок — строка, а не логическое значение',
        },
        {
            function()
                deflater:finish(helper.wrong({}))
            end,
            'кусок — строка, а не таблица',
        },
        {
            function()
                inflater:write(helper.wrong(nil))
            end,
            'кусок — строка, а не nil',
        },
    })
end
