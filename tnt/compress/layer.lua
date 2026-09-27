--- Слой `compress`: ответ сжимается gzip, если клиент его принимает.
---
--- Слой — фабрика для реестра `tnt-middleware` и слой сам по себе:
---
---     middleware.configure({ layers = { compress = compress.layer } })
---     -- { 'compress' }, { 'compress', { level = 4, min_size = 512 } }
---
---     router.new({ entry = { compress.layer() } })
---
--- Ставится на входе роутера: так сжимается всё, чем он отвечает, —
--- ответы API, страницы, раздача файлов и ответ по кускам.
---
--- Сжимается ответ, у которого тело — строка не короче `min_size` либо
--- поток (`router.stream`), тип — текст (`text/` любого вида, JSON,
--- JavaScript, XML, NDJSON, `…+json`, `…+xml`), а своего `content-encoding`
--- и `cache-control: no-transform` нет. Картинки, архивы и
--- `application/octet-stream` не сжимаются: они либо сжаты уже, либо
--- неизвестно что. Короткое тело не сжимается: обёртка gzip стоит
--- 18 байт, а ответ до килобайта уходит одним пакетом и так.
---
--- Ответу сжимаемого типа слой ставит `vary: Accept-Encoding` всегда —
--- и короткому, и ответу без тела (304, ответ на HEAD), и тогда, когда
--- клиент сжатия не просил: кэш по дороге обязан знать, что у адреса два
--- вида, иначе отдаст сжатый клиенту, не умеющему его читать.
---
--- Метку `etag` клиенту, принимающему gzip, слой помечает слабой (`W/`):
--- сжатое тело — другое представление (RFC 9110, 8.8.1), и сильная
--- метка, общая у двух видов, обещала бы одни и те же байты там, где
--- их нет, — кэш, собирающий ответ из кусков (`Range`), смешал бы байты
--- gzip с несжатыми. Сверка метки в роутере
--- (`tnt.router.files.caching.matched`) пометку `W/` снимает, и 304
--- по слабой метке приходит так же, как по сильной.
---
--- Правило метки и `vary` одно для 200, 304 и ответа на HEAD, и длина
--- тела в нём не участвует: у 304 и HEAD тела нет, и по ним не решить,
--- сжал бы слой ответ или нет. Короткий ответ клиенту с gzip
--- уходит несжатым, но со слабой меткой — RFC этого не запрещает, зато
--- 200 и 304 на один запрос несут одну и ту же метку и один `vary`,
--- и кэш сопоставляет 304 со своей копией (RFC 9111, 4.3.4; RFC 9110,
--- 15.4.5).
---
--- Ответ слой копирует, а не правит на месте: таблицу ответа обработчик
--- вправе отдавать одну и ту же на каждый запрос, и сжатое тело,
--- `content-encoding` и слабая метка, вписанные в неё, уехали бы
--- в следующие ответы — и клиенту без gzip тоже.
---
--- Сжатие только gzip. `deflate` HTTP — это обёртка zlib, но старые
--- браузеры читали его голым DEFLATE, и выигрыша против gzip он не даёт;
--- br и zstd в системе не найти так же верно, как zlib.
---
--- Поток сжимается кусок за куском со сбросом (`flush`): клиент
--- разжимает каждый кусок сразу, и выгрузка остаётся потоком — медленный
--- клиент по-прежнему тормозит источник, а не копит память узла.

local must = require('tnt.must')

local deflater = require('tnt.compress.deflater')
local zlib = require('tnt.compress.zlib')

local Module = {}

--- Тело короче этого, байт, не сжимается.
Module.MIN_SIZE = 1024

--- Кодирование ответа.
Module.ENCODING = 'gzip'

--- Что слой дописывает в `vary`.
Module.VARY = 'Accept-Encoding'

--- Сжимаемые типы, кроме текста и родов `+json`, `+xml`.
local TYPES = {
    ['application/json'] = true,
    ['application/javascript'] = true,
    ['application/xml'] = true,
    ['application/x-ndjson'] = true,
}

--- Сжимаемые роды типов по образцу.
local PATTERNS = { '^text%/', '%+json$', '%+xml$' }

--- Описание настроек слоя.
---
--- `tag` здесь потому, что реестр `tnt-middleware` кладёт свою метку
--- журнала в настройки каждого слоя.
local OPTIONS = {
    level = '?integer',
    min_size = '?integer',
    tag = '?string',
}

---@class TntCompressLayerOptions
---@field level integer|nil Уровень сжатия, 0…9; по умолчанию 6
---@field min_size integer|nil Тело короче этого, байт, не сжимается; по умолчанию 1024
---@field tag string|nil Метка журнала; её кладёт реестр `tnt-middleware`, слою она не нужна

--- Сжимается ли тело такого типа: `true` либо ничего.
---
--- Предикаты слоя отвечают «да» либо молчат: `false` и `nil` для их
--- развилок одно и то же, и явный `return false` был бы строкой, поломку
--- которой не заметит никто.
---@param content_type any
---@return true|nil
local function compressible(content_type)
    if type(content_type) == 'string' then
        -- Образец совпадает всегда, хотя бы пустой строкой.
        local media = (content_type:match('^%s*([^;%s]*)') --[[@as string]]):lower()

        if TYPES[media] then
            return true
        end

        for _, pattern in ipairs(PATTERNS) do
            if media:find(pattern) ~= nil then
                return true
            end
        end
    end
end

--- Годится ли ответ для сжатия — независимо от того, просил ли клиент
--- и какой длины тело: `true` либо ничего.
---@param response any
---@return true|nil
local function negotiable(response)
    local headers = type(response) == 'table' and response.headers or nil

    if type(headers) ~= 'table' or headers['content-encoding'] ~= nil then
        return
    end

    local cache = headers['cache-control']

    if type(cache) == 'string' and cache:lower():find('no%-transform') ~= nil then
        return
    end

    return compressible(headers['content-type'])
end

--- Хватает ли тела на сжатие: строка не короче порога либо поток.
---@param body any
---@param min_size integer
---@return boolean
local function sized(body, min_size)
    return type(body) == 'function' or type(body) == 'string' and #body >= min_size
end

--- Принят ли элемент `Accept-Encoding` по весу: `gzip;q=0.5` — да,
--- `gzip;q=0` — нет.
---
--- Веса нет — принят; вес не числом — нет: сжатие, о котором клиент
--- сказал невнятно, ему не шлют.
---@param parameters string Всё после имени кодирования
---@return boolean
local function acceptable(parameters)
    local given = parameters:match(';%s*[qQ]%s*=%s*([^;%s]*)')

    if given == nil then
        return true
    end

    local weight = tonumber(given)

    return weight ~= nil and weight > 0
end

--- Принимает ли клиент gzip (RFC 9110, §12.5.3).
---
--- Своё имя (`gzip`, `x-gzip`) важнее звёздочки, вес 0 — отказ.
--- Без заголовка — нет: RFC разрешает тогда слать что угодно, но
--- клиент, не назвавший gzip, его обычно и не читает.
---@param request any
---@return boolean|nil
local function accepts(request)
    local headers = type(request) == 'table' and request.headers or nil
    local header = type(headers) == 'table' and headers['accept-encoding'] or nil

    if type(header) ~= 'string' then
        return
    end

    ---@type boolean|nil, boolean|nil
    local named, any

    -- Элементы — до каждой запятой; пустой элемент (`br, , gzip`) даёт
    -- пустое имя и ни с чем не совпадает. Образец имени совпадает всегда.
    for item in (header .. ','):gmatch('(.-),') do
        local coding, parameters = item:match('^%s*([^;%s]*)%s*(.*)$')

        coding = (coding --[[@as string]]):lower()

        if coding == 'gzip' or coding == 'x-gzip' then
            named = acceptable(parameters --[[@as string]])
        elseif coding == '*' then
            any = acceptable(parameters --[[@as string]])
        end
    end

    if named ~= nil then
        return named
    end

    return any == true
end

--- Дописывает `Accept-Encoding` в `vary`.
---
--- Значение не строкой (список значений заголовка) слой не разбирает
--- и оставляет как есть.
---@param headers table
local function vary(headers)
    local current = headers.vary

    if current == nil or current == '' then
        headers.vary = Module.VARY
    elseif type(current) == 'string' and current:lower():find('accept%-encoding') == nil then
        headers.vary = current .. ', ' .. Module.VARY
    end
end

--- Помечает сильную метку слабой (RFC 9110, 8.8.1).
---
--- Сильная метка начинается с кавычки, слабая — с `W/`, и второй пометки
--- она не получает. Прочее — не метка вовсе (RFC 9110, 8.8.3): такое
--- слой не толкует и оставляет как есть, как и список значений.
---@param headers table
local function weaken(headers)
    local tag = headers.etag

    if type(tag) == 'string' and tag:find('^"') ~= nil then
        headers.etag = 'W/' .. tag
    end
end

--- Мелкая копия таблицы с её метатаблицей.
---
--- Метатаблица сохраняется: тот, кто выдал ответ, вправе узнавать его
--- по ней. Берётся она мимо `__metatable` — `getmetatable` отдал бы
--- вместо закрытой метатаблицы её заглушку.
---@param value table
---@return table
local function shallow(value)
    local copy = {}

    for key, field in pairs(value) do
        copy[key] = field
    end

    return setmetatable(copy, debug.getmetatable(value))
end

--- Поток ответа, сжатый кусок за куском.
---
--- Кусок сжимается со сбросом: иначе zlib копила бы его до блока,
--- и клиент ждал бы. Пустой выход не отдаётся — пустой кусок сервер
--- отправил бы концом тела. Отказ источника бросается как был: роутер
--- рвёт соединение без завершающего куска, и обрыв остаётся обрывом.
---
--- Хвост потока — последний кусок, и следующий вызов — уже конец:
--- цикл `for` зовёт тело ещё раз, чтобы получить `nil`.
---@param body fun(): string|nil
---@param level integer
---@return fun(): string|nil, string|nil
local function streamed(body, level)
    local packing = deflater.new({ level = level })
    local finished = false

    return function()
        while not finished do
            local part = body()

            if part == nil then
                finished = true

                local tail = packing:finish()

                return tail, tail
            end

            local packed = packing:flush(tostring(part))

            if packed ~= '' then
                return packed, packed
            end
        end

        return nil
    end
end

--- Сжимает ответ: тело, кодирование, длина.
---@param response table
---@param level integer
local function encode(response, level)
    local headers = response.headers

    headers['content-encoding'] = Module.ENCODING
    -- Длину сжатого строкой ставит сервер сам, а у потока её нет вовсе:
    -- оставленная прежняя длина разошлась бы с телом.
    headers['content-length'] = nil

    if type(response.body) == 'string' then
        response.body = deflater.deflate(response.body, { level = level })
    else
        response.body = streamed(response.body, level)
    end
end

--- Собирает слой.
---
--- Негодные настройки и узел без zlib — бросок при сборке, на строку
--- того, кто собирает: узнать об этом надо при настройке, а не на первом
--- ответе.
---@param options TntCompressLayerOptions|nil
---@return fun(request: any, next_layer: fun(request: any): any, any): any, any
function Module.new(options)
    local caller = must.at(2)

    caller.optional.options(options, 'настройки слоя', OPTIONS)

    local given = options or {}
    local level = given.level or deflater.LEVEL
    local min_size = given.min_size or Module.MIN_SIZE

    caller.between(level, 'настройки слоя.level', 0, 9)
    caller.non_negative(min_size, 'настройки слоя.min_size')

    local ready, missing = zlib.available()

    if not ready then
        error(missing, 2)
    end

    return function(request, next_layer)
        local response, failed = next_layer(request)

        if not negotiable(response) then
            return response, failed
        end

        local answer = shallow(response)

        answer.headers = shallow(response.headers)
        vary(answer.headers)

        if accepts(request) then
            weaken(answer.headers)

            if sized(answer.body, min_size) then
                encode(answer, level)
            end
        end

        return answer, failed
    end
end

return Module
