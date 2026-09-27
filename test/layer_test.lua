--- Проверки слоя `compress`: что сжимается, как и с какими заголовками.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local compress = helper.compress
local MIN_SIZE = helper.layer.MIN_SIZE --[[@as integer]]

local g = t.group('tnt.compress.layer')

g.after_each(helper.restore)

--- Тело ответа API длиннее порога.
local BODY = string.rep('{"id":1,"name":"storage-001","state":"alive"}\n', 40)

--- Запрос с названным `Accept-Encoding`.
---@param accepted string|nil
---@return table
local function request(accepted)
    return { method = 'GET', path = '/api', headers = { ['accept-encoding'] = accepted } }
end

--- Ответ с телом и заголовками; тип — JSON, если не сказано иначе.
---@param body any
---@param headers table|nil
---@return table
local function response(body, headers)
    local prepared = { ['content-type'] = 'application/json; charset=utf-8' }

    for name, value in pairs(headers or {}) do
        prepared[name] = value
    end

    return { status = 200, headers = prepared, body = body }
end

--- Проводит запрос через слой к обработчику, отвечающему заготовкой.
---@param layer function
---@param incoming any
---@param answer any
---@param failure any
---@return any response
---@return any failure
local function pass(layer, incoming, answer, failure)
    return layer(incoming, function()
        return answer, failure
    end)
end

--- Сжат ли ответ: кодирование, `vary` и тело, разжимающееся в исходное.
---@param answer table
---@param body string
local function assert_compressed(answer, body)
    t.assert_equals(answer.headers['content-encoding'], 'gzip')
    t.assert_equals(answer.headers.vary, 'Accept-Encoding')
    t.assert_equals(compress.inflate(answer.body), body)
end

g.test_a_client_accepting_gzip_gets_it = function()
    local answer = pass(compress.layer(), request('gzip, deflate, br'), response(BODY, { ['content-length'] = '4' }))

    assert_compressed(answer, BODY)
    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.headers['content-type'], 'application/json; charset=utf-8')
    -- Прежняя длина разошлась бы со сжатым телом.
    t.assert_equals(answer.headers['content-length'], nil)
    -- Уровень по умолчанию — шестой, как у пакета.
    t.assert_equals(answer.body, compress.deflate(BODY))
end

g.test_the_weight_decides = function()
    for _, accepted in ipairs({
        'gzip',
        'x-gzip',
        'GZIP',
        '*',
        'gzip;q=0.5',
        'deflate, gzip ; q = 1',
        'br, , gzip',
        'identity;q=0, *',
        '*;q=0, gzip',
        'gzip;level=1;q=0.1',
    }) do
        local answer = pass(compress.layer(), request(accepted), response(BODY))

        t.assert_equals(answer.headers['content-encoding'], 'gzip', accepted)
    end

    for _, accepted in ipairs({
        'br',
        'deflate, br;q=1',
        'gzip;q=0',
        'gzip;q=0.000',
        '*;q=0',
        'gzip;q=0, *',
        'gzip;q=abc',
        'gzip;q=',
        'gzip;q=-1',
        'gzipped',
        '',
    }) do
        local answer = pass(compress.layer(), request(accepted), response(BODY))

        t.assert_equals(answer.headers['content-encoding'], nil, accepted)
        t.assert_equals(answer.body, BODY, accepted)
        -- Вид у адреса всё равно два: кэш обязан это знать.
        t.assert_equals(answer.headers.vary, 'Accept-Encoding', accepted)
    end
end

g.test_a_request_without_the_header_gets_the_plain_body = function()
    for _, incoming in ipairs({ request(nil), { method = 'GET', path = '/' }, 'не запрос' }) do
        local answer = pass(compress.layer(), incoming, response(BODY))

        t.assert_equals(answer.body, BODY)
        t.assert_equals(answer.headers['content-encoding'], nil)
        t.assert_equals(answer.headers.vary, 'Accept-Encoding')
    end

    local listed = { method = 'GET', path = '/', headers = { ['accept-encoding'] = { 'gzip' } } }

    t.assert_equals(pass(compress.layer(), listed, response(BODY)).body, BODY)
end

g.test_a_short_body_is_not_compressed = function()
    t.assert_equals(MIN_SIZE, 1024)

    local short = BODY:sub(1, MIN_SIZE - 1)
    local answer = pass(compress.layer(), request('gzip'), response(short))

    -- Сжатия нет, а `vary` есть: правило `vary` от длины не зависит.
    t.assert_equals(answer, response(short, { vary = 'Accept-Encoding' }))

    assert_compressed(pass(compress.layer(), request('gzip'), response(BODY:sub(1, MIN_SIZE))), BODY:sub(1, MIN_SIZE))

    -- Порог — настройкой.
    local layer = compress.layer({ min_size = 10 })

    assert_compressed(pass(layer, request('gzip'), response('0123456789')), '0123456789')
    t.assert_equals(pass(layer, request('gzip'), response('012345678')).body, '012345678')
    assert_compressed(pass(compress.layer({ min_size = 0 }), request('gzip'), response('')), '')
end

g.test_only_text_is_compressed = function()
    for _, kind in ipairs({
        'text/html; charset=utf-8',
        'text/css',
        'application/json',
        ' APPLICATION/JSON ; charset=utf-8',
        'application/javascript',
        'application/xml',
        'application/x-ndjson',
        'application/problem+json',
        'image/svg+xml',
    }) do
        local answer = pass(compress.layer(), request('gzip'), response(BODY, { ['content-type'] = kind }))

        t.assert_equals(answer.headers['content-encoding'], 'gzip', kind)
    end

    for _, kind in ipairs({
        'image/png',
        'application/octet-stream',
        'application/zip',
        'application/json+zip',
        'texture/x-demo',
        '',
    }) do
        local answer = pass(compress.layer(), request('gzip'), response(BODY, { ['content-type'] = kind }))

        t.assert_equals(answer, response(BODY, { ['content-type'] = kind }), kind)
    end

    local untyped = { status = 200, headers = { ['cache-control'] = 'no-cache' }, body = BODY }

    t.assert_equals(pass(compress.layer(), request('gzip'), untyped).body, BODY)
end

g.test_an_encoded_or_untransformable_answer_is_left_alone = function()
    local encoded = response(BODY, { ['content-encoding'] = 'br' })

    t.assert_equals(pass(compress.layer(), request('gzip'), encoded), response(BODY, { ['content-encoding'] = 'br' }))

    local fixed = response(BODY, { ['cache-control'] = 'private, No-Transform' })

    t.assert_equals(
        pass(compress.layer(), request('gzip'), fixed),
        response(BODY, { ['cache-control'] = 'private, No-Transform' })
    )

    local cached = pass(compress.layer(), request('gzip'), response(BODY, { ['cache-control'] = 'no-cache' }))

    t.assert_equals(cached.headers['content-encoding'], 'gzip')
end

g.test_vary_keeps_what_was_there = function()
    local cases = {
        { given = 'Origin', expected = 'Origin, Accept-Encoding' },
        { given = 'origin, accept-encoding', expected = 'origin, accept-encoding' },
        { given = '', expected = 'Accept-Encoding' },
    }

    for _, case in ipairs(cases) do
        local answer = pass(compress.layer(), request('gzip'), response(BODY, { vary = case.given }))

        t.assert_equals(answer.headers.vary, case.expected, case.given)
    end

    -- Список значений слой не разбирает.
    local listed = pass(compress.layer(), request('gzip'), response(BODY, { vary = { 'Origin' } }))

    t.assert_equals(listed.headers.vary, { 'Origin' })
    t.assert_equals(listed.headers['content-encoding'], 'gzip')
end

g.test_what_is_not_an_answer_passes_through = function()
    t.assert_equals({ pass(compress.layer(), request('gzip'), nil, 'нет связи') }, { nil, 'нет связи' })
    t.assert_equals(pass(compress.layer(), request('gzip'), 'строка'), 'строка')

    local headless = { status = 200, headers = 'не таблица', body = BODY }

    t.assert_is(pass(compress.layer(), request('gzip'), headless), headless)
end

g.test_an_answer_without_a_body_gets_vary_and_is_not_encoded = function()
    -- 304 и ответ на HEAD: длины тела нет, и сжал бы слой его или нет,
    -- не узнать — `vary` у них тот же, что у ответа 200 на этот адрес.
    local cases = {
        { status = 304, headers = { ['content-type'] = 'text/css' } },
        { status = 200, headers = { ['content-type'] = 'text/css', ['content-length'] = '4096' }, body = '' },
        { status = 200, headers = { ['content-type'] = 'text/css' }, body = { gen = next } },
    }

    for index, case in ipairs(cases) do
        for _, accepted in ipairs({ 'gzip', 'br' }) do
            local expected = table.deepcopy(case)
            local answer = pass(compress.layer(), request(accepted), case)

            expected.headers.vary = 'Accept-Encoding'

            t.assert_equals(answer, expected, index .. ' ' .. accepted)
        end
    end
end

--- Ответ с меткой версии.
---@param status integer
---@param body any
---@param tag any
---@return table
local function tagged(status, body, tag)
    local answer = response(body, { etag = tag })

    answer.status = status

    return answer
end

g.test_the_tag_is_weak_for_a_client_accepting_gzip = function()
    local layer = compress.layer()

    -- Сжатый ответ — другое представление: сильная метка обещала бы
    -- те же байты, что у несжатого.
    local sent = pass(layer, request('gzip'), tagged(200, BODY, '"5f1d"'))

    assert_compressed(sent, BODY)
    t.assert_equals(sent.headers.etag, 'W/"5f1d"')

    -- 304, ответ на HEAD и короткий ответ несут ту же метку: длина тела
    -- в правиле метки не участвует.
    for index, case in ipairs({
        { status = 304 },
        { status = 200, body = '' },
        { status = 200, body = 'коротко' },
    }) do
        local answer = pass(layer, request('gzip'), tagged(case.status, case.body, '"5f1d"'))
        local expected = tagged(case.status, case.body, 'W/"5f1d"')

        expected.headers.vary = 'Accept-Encoding'

        t.assert_equals(answer, expected, index)
    end
end

g.test_the_tag_stays_strong_without_gzip = function()
    local layer = compress.layer()

    for _, incoming in ipairs({ request(nil), request('br'), request('gzip;q=0') }) do
        local sent = pass(layer, incoming, tagged(200, BODY, '"5f1d"'))

        t.assert_equals(sent.headers.etag, '"5f1d"')
        t.assert_equals(sent.headers.vary, 'Accept-Encoding')
        t.assert_equals(sent.body, BODY)

        local unchanged = pass(layer, incoming, tagged(304, nil, '"5f1d"'))

        t.assert_equals(unchanged.headers.etag, '"5f1d"')
        t.assert_equals(unchanged.headers.vary, 'Accept-Encoding')
    end
end

g.test_only_a_strong_tag_is_weakened = function()
    -- Слабая метка второй пометки не получает; без кавычек — не метка,
    -- а список значений слой не толкует.
    for index, tag in ipairs({ 'W/"5f1d"', '5f1d', '', { '"5f1d"' } }) do
        local answer = pass(compress.layer(), request('gzip'), tagged(304, nil, tag))

        t.assert_equals(answer.headers.etag, tag, index)
        t.assert_equals(answer.headers.vary, 'Accept-Encoding', index)
    end

    -- Ответ, который слой не сжимает по типу, по кодированию или по
    -- запрету, остаётся со своей меткой и без `vary`.
    for _, headers in ipairs({
        { ['content-type'] = 'image/png' },
        { ['content-encoding'] = 'br' },
        { ['cache-control'] = 'no-transform' },
    }) do
        local given = tagged(200, BODY, '"5f1d"')

        for name, value in pairs(headers) do
            given.headers[name] = value
        end

        local answer = pass(compress.layer(), request('gzip'), given)

        t.assert_is(answer, given)
        t.assert_equals(answer.headers.etag, '"5f1d"')
        t.assert_equals(answer.headers.vary, nil)
    end
end

g.test_the_handlers_answer_is_not_changed = function()
    -- Обработчик вправе отдавать одну таблицу на каждый запрос: то, что
    -- слой сделал для клиента с gzip, не уезжает следующему клиенту.
    local mark = { __metatable = 'закрыто' }
    local shared = setmetatable(tagged(200, BODY, '"5f1d"'), mark)
    local layer = compress.layer()
    local sent = pass(layer, request('gzip'), shared)

    assert_compressed(sent, BODY)
    t.assert_equals(shared, tagged(200, BODY, '"5f1d"'))
    t.assert_is(debug.getmetatable(sent), mark)

    local plain = pass(layer, request(nil), shared)

    t.assert_equals(plain.body, BODY)
    t.assert_equals(plain.headers.etag, '"5f1d"')
    t.assert_equals(plain.headers['content-encoding'], nil)
end

--- Поток, как его отдаёт роутер: кусок и он же вторым значением.
---@param parts any[]
---@return fun(): any, any
local function stream_of(parts)
    local index = 0

    return function()
        index = index + 1

        return parts[index], parts[index]
    end
end

--- Обходит тело-поток так, как его обходит сервер.
---@param body function
---@return string[]
local function drain(body)
    local pieces = {}

    for _, piece in body do
        table.insert(pieces, piece)
    end

    return pieces
end

g.test_a_stream_is_compressed_piece_by_piece = function()
    local answer = pass(
        compress.layer(),
        request('gzip'),
        response(
            stream_of({ 'первая\n', '', 'вторая\n', 3 }),
            { ['content-type'] = 'application/x-ndjson' }
        )
    )

    t.assert_equals(answer.headers['content-encoding'], 'gzip')
    t.assert_equals(answer.headers.vary, 'Accept-Encoding')

    local pieces = drain(answer.body)

    -- Пустой кусок источника выхода не дал: пустой кусок сервер отправил
    -- бы концом тела. Каждый кусок читается сразу, не дожидаясь конца.
    t.assert_equals(#pieces, 4)

    local inflater = compress.inflater()

    t.assert_equals(inflater:write(pieces[1]), 'первая\n')
    t.assert_equals(inflater:write(pieces[2]), 'вторая\n')
    t.assert_equals(inflater:write(pieces[3]), '3')
    t.assert_equals(inflater:write(pieces[4]), '')
    t.assert_equals(inflater:finish(), true)
end

g.test_a_stream_of_the_wrong_type_is_left_alone = function()
    local body = stream_of({ 'a' })
    local answer =
        pass(compress.layer(), request('gzip'), response(body, { ['content-type'] = 'application/octet-stream' }))

    t.assert_is(answer.body, body)
    t.assert_equals(answer.headers['content-encoding'], nil)
end

g.test_a_broken_source_breaks_the_stream = function()
    local answer = pass(
        compress.layer(),
        request('gzip'),
        response(function()
            error('поток ответа оборван', 0)
        end)
    )

    t.assert_error_msg_equals('поток ответа оборван', function()
        answer.body()
    end)
end

g.test_the_level_is_a_setting = function()
    local answer = pass(compress.layer({ level = 1, tag = 'app.http' }), request('gzip'), response(BODY))

    t.assert_equals(answer.body, compress.deflate(BODY, { level = 1 }))

    local streamed = pass(compress.layer({ level = 0 }), request('gzip'), response(stream_of({ BODY })))
    local pieces = drain(streamed.body)

    -- Нулевой уровень хранит кусок как есть: сжатое длиннее исходного.
    t.assert_gt(#pieces[1], #BODY)
    t.assert_equals(compress.inflate(table.concat(pieces)), BODY)
end

g.test_bad_options_blame_the_caller = function()
    helper.assert_blamed({
        {
            function()
                compress.layer(helper.wrong('gzip'))
            end,
            'настройки слоя — таблица, а не строка',
        },
        {
            function()
                compress.layer(helper.wrong({ levle = 1 }))
            end,
            'настройки слоя: ключа «levle» нет, есть level, min_size, tag',
        },
        {
            function()
                compress.layer({ level = 10 })
            end,
            'настройки слоя.level — число от 0 до 9, а не 10',
        },
        {
            function()
                compress.layer({ level = -1 })
            end,
            'настройки слоя.level — число от 0 до 9, а не -1',
        },
        {
            function()
                compress.layer({ min_size = -1 })
            end,
            'настройки слоя.min_size — число не меньше 0, а не -1',
        },
        {
            function()
                compress.layer({ min_size = 1.5 })
            end,
            'настройки слоя.min_size — целое число, а не 1.5',
        },
    })
end

g.test_a_node_without_zlib_fails_when_the_layer_is_built = function()
    helper.compress._set_source({
        load = function(name)
            error('нет ' .. name, 0)
        end,
    })

    helper.assert_blamed({
        {
            function()
                compress.layer()
            end,
            'нет системной библиотеки zlib: нет z; нет libz.so.1',
        },
    })
end
