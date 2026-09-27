--- Стык слоя с соседями: роутер, реестр слоёв, раздача файлов и сервер.
---
--- Собственные проверки слоя сверяют его договор с самим собой. Здесь
--- слой стоит там, где его поставит приложение, — на входе настоящего
--- роутера и именем в реестре `tnt-middleware`, — а ответ читает libcurl
--- через `http.client` с настоящего `http.server`: сжатое нами обязано
--- разжиматься чужим разжимателем, а не только своим.

local t = require('luatest')
local http_client = require('http.client')
local http_server = require('http.server')
local json = require('json')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.compress.contract')

g.before_all(function()
    local loaded = helper.load_neighbours()

    g.compress = loaded.compress
    g.middleware = loaded.middleware
    g.router = loaded.router
end)

g.after_all(helper.unload_neighbours)

--- Список узлов длиннее порога сжатия.
local NODES = {}

for index = 1, 50 do
    NODES[index] = { name = ('storage-%03d'):format(index), state = 'alive' }
end

--- Файл панели длиннее порога сжатия.
local SCRIPT = string.rep('const a = 1;\n', 200)

--- Роутер со слоем сжатия на входе и тремя видами ответа.
---@return table
local function routed()
    local r = g.router.new({ entry = { g.compress.layer() } })

    r.get('/nodes', function()
        return g.router.json({ nodes = NODES })
    end)

    r.get('/export', function()
        local left = 3

        return g.router.stream(function()
            if left == 0 then
                return nil
            end

            left = left - 1

            return json.encode(NODES[left + 1]) .. '\n'
        end, 200, { ['content-type'] = 'application/x-ndjson' })
    end)

    r.get('/panel/*path', g.router.files({ bundle = { ['app.js'] = SCRIPT } }))

    return r
end

--- Запрос к роутеру.
---@param path string
---@param headers table|nil
---@param method string|nil
---@return table
local function ask(r, path, headers, method)
    return r.dispatch({ method = method or 'GET', path = path, headers = headers or {} })
end

g.test_the_router_answers_compressed = function()
    local answer = ask(routed(), '/nodes', { ['accept-encoding'] = 'gzip' })

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.headers['content-encoding'], 'gzip')
    t.assert_equals(answer.headers.vary, 'Accept-Encoding')
    t.assert_equals(json.decode(g.compress.inflate(answer.body)), { nodes = NODES })

    local plain = ask(routed(), '/nodes')

    t.assert_equals(json.decode(plain.body --[[@as string]]), { nodes = NODES })
    t.assert_equals(plain.headers.vary, 'Accept-Encoding')
end

g.test_the_files_keep_answering_304 = function()
    local r = routed()
    local first = ask(r, '/panel/app.js', { ['accept-encoding'] = 'gzip' })

    t.assert_equals(first.headers['content-encoding'], 'gzip')
    t.assert_equals(g.compress.inflate(first.body), SCRIPT)
    t.assert_str_matches(first.headers.etag, 'W/"%x+"')

    -- Слабую метку браузер присылает назад как есть, раздача снимает
    -- пометку при сверке и отвечает 304 без тела — с той же меткой
    -- и тем же `vary`, что у 200, со сроком жизни копии, которым клиент
    -- продлевает свою запись в кэше, и с типом: без него сервер подставил
    -- бы свой. Сжимать без тела нечего, и кодирования у 304 нет.
    local again = ask(r, '/panel/app.js', { ['accept-encoding'] = 'gzip', ['if-none-match'] = first.headers.etag })
    local expected = { etag = first.headers.etag, ['cache-control'] = 'no-cache', vary = 'Accept-Encoding' }

    expected['content-type'] = 'application/javascript; charset=utf-8'

    t.assert_equals(again.status, 304)
    t.assert_equals(again.body, nil)
    t.assert_equals(again.headers, expected)

    -- Клиенту без gzip метка остаётся сильной, и 304 он получает по ней.
    local plain = ask(r, '/panel/app.js')
    local unchanged = ask(r, '/panel/app.js', { ['if-none-match'] = plain.headers.etag })

    t.assert_equals(plain.body, SCRIPT)
    t.assert_equals('W/' .. plain.headers.etag, first.headers.etag)
    t.assert_equals(unchanged.status, 304)
    t.assert_equals(unchanged.headers.etag, plain.headers.etag)
    t.assert_equals(unchanged.headers.vary, 'Accept-Encoding')
end

g.test_the_delivery_compresses_through_its_own_setting = function()
    -- Раздача берёт слой своей настройкой `compress`, а не входом роутера:
    -- так сжимаются её файлы, а ответы остальных маршрутов — нет. Роутер
    -- не знает, чем сжимают, и отдаёт слою свой ответ следующим шагом.
    local r = g.router.new()

    r.get('/panel/*path', g.router.files({ bundle = { ['app.js'] = SCRIPT }, compress = g.compress.layer() }))

    local sent = ask(r, '/panel/app.js', { ['accept-encoding'] = 'gzip' })

    t.assert_equals(sent.headers['content-encoding'], 'gzip')
    t.assert_equals(sent.headers.vary, 'Accept-Encoding')
    t.assert_equals(g.compress.inflate(sent.body), SCRIPT)

    local plain = ask(r, '/panel/app.js')

    t.assert_equals(plain.body, SCRIPT)
    t.assert_equals(plain.headers['content-encoding'], nil)
    t.assert_equals(sent.headers.etag, 'W/' .. plain.headers.etag)
end

g.test_head_gets_the_tag_and_vary_of_get = function()
    local r = routed()
    local answer = ask(r, '/nodes', { ['accept-encoding'] = 'gzip' }, 'HEAD')

    t.assert_equals(answer.body, '')
    t.assert_equals(answer.headers['content-encoding'], nil)
    t.assert_equals(answer.headers.vary, 'Accept-Encoding')

    -- Метка и `vary` у HEAD — те же, что у GET: правило о них длины
    -- тела не спрашивает.
    local sent = ask(r, '/panel/app.js', { ['accept-encoding'] = 'gzip' })
    local head = ask(r, '/panel/app.js', { ['accept-encoding'] = 'gzip' }, 'HEAD')

    t.assert_equals(head.headers.etag, sent.headers.etag)
    t.assert_equals(head.headers.vary, 'Accept-Encoding')
    t.assert_equals(head.headers['content-encoding'], nil)
end

g.test_the_stream_stays_a_stream = function()
    local answer = ask(routed(), '/export', { ['accept-encoding'] = 'gzip' })
    local inflater = g.compress.inflater()
    local lines = {}

    for _, piece in answer.body do
        table.insert(lines, inflater:write(piece))
    end

    t.assert_equals(answer.headers['content-encoding'], 'gzip')
    t.assert_equals(lines, {
        json.encode(NODES[3]) .. '\n',
        json.encode(NODES[2]) .. '\n',
        json.encode(NODES[1]) .. '\n',
        '',
    })
    t.assert_equals(inflater:finish(), true)
end

g.test_the_registry_builds_the_layer_by_name = function()
    local registry = g.middleware.new({ layers = { compress = g.compress.layer } })
    local handle = registry:chain({ { 'compress', { min_size = 0 } } }):wrap(function()
        return g.router.text('коротко')
    end)
    local answer = handle({ headers = { ['accept-encoding'] = 'gzip' } })

    t.assert_equals(answer.headers['content-encoding'], 'gzip')
    t.assert_equals(g.compress.inflate(answer.body), 'коротко')
end

--- Проводит работу через настоящий `http.server` с роутером.
---
--- Сервер гасится и тогда, когда проверка внутри упала: иначе он
--- держал бы порт до конца процесса проверок.
---@param r table Роутер
---@param work fun(base: string, client: table)
local function over_network(r, work)
    local httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })

    r.attach(httpd)
    httpd:start()

    local ok, failure = pcall(work, ('http://127.0.0.1:%d'):format(httpd.tcp_server:name().port), http_client.new())

    httpd:stop()

    if not ok then
        error(failure, 0)
    end
end

g.test_curl_reads_what_the_server_sends = function()
    over_network(routed(), function(base, client)
        -- libcurl просит gzip и разжимает сам; без просьбы тело идёт как есть.
        local compressed = client:get(base .. '/nodes', { accept_encoding = 'gzip', timeout = 5 })
        local plain = client:get(base .. '/nodes', { timeout = 5 })
        local streamed = client:get(base .. '/export', { accept_encoding = 'gzip', timeout = 5 })

        t.assert_equals(compressed.status, 200)
        t.assert_equals(compressed.headers['content-encoding'], 'gzip')
        t.assert_equals(json.decode(compressed.body --[[@as string]]), { nodes = NODES })

        t.assert_equals(plain.headers['content-encoding'], nil)
        t.assert_equals(json.decode(plain.body --[[@as string]]), { nodes = NODES })

        t.assert_equals(streamed.headers['content-encoding'], 'gzip')
        t.assert_equals(streamed.headers['transfer-encoding'], 'chunked')
        t.assert_equals(
            streamed.body,
            json.encode(NODES[3]) .. '\n' .. json.encode(NODES[2]) .. '\n' .. json.encode(NODES[1]) .. '\n'
        )
    end)
end

g.test_the_served_delivery_answers_304_to_the_weak_tag = function()
    local r = g.router.new()

    r.get('/panel/*path', g.router.files({ bundle = { ['app.js'] = SCRIPT }, compress = g.compress.layer() }))

    over_network(r, function(base, client)
        local url = base .. '/panel/app.js'
        local first = client:get(url, { accept_encoding = 'gzip', timeout = 5 })

        t.assert_equals(first.status, 200)
        t.assert_equals(first.body, SCRIPT)
        t.assert_str_matches(first.headers.etag, 'W/"%x+"')
        t.assert_equals(first.headers.vary, 'Accept-Encoding')

        -- Второй запрос — как у браузера: с меткой, полученной в первом.
        local again = client:get(url, {
            accept_encoding = 'gzip',
            headers = { ['if-none-match'] = first.headers.etag },
            timeout = 5,
        })

        t.assert_equals(again.status, 304)
        t.assert_equals(again.headers.etag, first.headers.etag)
        t.assert_equals(again.headers.vary, 'Accept-Encoding')
    end)
end
