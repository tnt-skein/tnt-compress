--- Общие средства проверок сжатия.
---
--- Сжатие проверяется настоящей zlib: пакет — тонкий слой над ней,
--- и двойник проверял бы, что мы правильно разговариваем сами с собой.
--- Двойник берётся только там, где настоящая библиотека не даст нужного
--- случая: узел без zlib, отказ по памяти.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must` и `tnt.external` — и соседи стыка — `tnt.router`
--- с роком `http` и `tnt.middleware` — берутся из `.rocks` обычным
--- `require`: проверяется этот пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников, файлы и временный
--- узел — грузится так же, файлами, и один раз на процесс: второй
--- экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул бы
--- вытесненное на место.
---
--- Проверки сжатия берут всё через помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local ffi = require('ffi')
local fio = require('fio')
local json = require('json')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: временный узел берёт
--- загрузчик и файлы.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    start_node = package.loaded['tnt.testing.node'].start,
    stop_node = package.loaded['tnt.testing.node'].stop,
}

local helper = {
    --- Модули пакета в порядке зависимостей: имя и путь исходника.
    MODULES = {},
}

for _, name in ipairs(dofile('test/sources.lua')) do
    table.insert(helper.MODULES, { name = name, path = (name:gsub('%.', '/')) .. '.lua' })
end

--- Фасад пакета из исходников.
---
--- Грузится один раз на файл проверок: состояния у пакета нет, кроме
--- внешних зависимостей и найденной библиотеки, а внешние зависимости
--- проверки возвращают сами (`restore`).
helper.compress = testing.load_sources(helper.MODULES, 'tnt.compress')

--- Части пакета из той же загрузки, что и фасад.
helper.deflater = testing.module('tnt.compress.deflater')
helper.failure = testing.module('tnt.compress.failure')
helper.inflater = testing.module('tnt.compress.inflater')
helper.layer = testing.module('tnt.compress.layer')
helper.stream = testing.module('tnt.compress.stream')
helper.system = testing.module('tnt.compress.system')
helper.zlib = testing.module('tnt.compress.zlib')

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Настоящая библиотека — мимо поиска пакета.
---
--- Помощник грузится до первой проверки, и поиск пакета здесь уронил бы
--- загрузку на его же мутанте: проверки не запустились бы вовсе,
--- а мутант числился бы убитым, ничего не проверив.
---@return any
local function real_library()
    local ok, library = pcall(ffi.load, 'z')

    if ok then
        return library
    end

    return ffi.load('libz.so.1')
end

helper.real = real_library()

--- Возвращает пакету настоящие средства.
function helper.restore()
    helper.compress._set_source(nil)
end

--- Грузит исходники пакета ещё раз и отдаёт новый фасад: так их грузит
--- каждая проверка, взявшая пакет заново.
---@return table
function helper.load_again()
    return testing.load_sources(helper.MODULES, 'tnt.compress')
end

--- Соседи стыка — реестр слоёв и роутер — из `.rocks`, пакет — тот же,
--- что у остальных проверок: зависимостью соседи пакет не берут, и грузить
--- его заново вместе с ними незачем.
---@return { compress: table, middleware: table, router: table }
function helper.load_neighbours()
    return {
        compress = helper.compress,
        middleware = require('tnt.middleware'),
        router = require('tnt.router'),
    }
end

--- Соседи стыка стоят в `.rocks`, и выгружать после проверок стыка нечего.
function helper.unload_neighbours() end

--- Заводит группу проверок на временном узле с исходниками пакета:
--- настоящий `box` и транзакция в нём.
---
--- Узел лежит в `g.server`: поднимается перед первой проверкой группы
--- и останавливается после последней вместе со своим каталогом.
---@param name string
---@return table g Группа luatest
function helper.node_group(name)
    local g = t.group(name)

    g.before_all(function()
        g.server = testing.start_node({ modules = helper.MODULES })
    end)

    g.after_all(function()
        testing.stop_node(g.server)
    end)

    return g
end

--- Считает уступки; признак транзакции — свой либо настоящий.
---@param in_txn (fun(): boolean)|nil
---@return { count: integer }
function helper.yields(in_txn)
    local seen = { count = 0 }

    helper.compress._set_source({
        yield = function()
            seen.count = seen.count + 1
        end,
        in_txn = in_txn,
    })

    return seen
end

--- Ставит пакету библиотеку, у которой подменены названные функции.
---@param overrides table<string, function>
function helper.library(overrides)
    local fake = setmetatable(overrides, { __index = helper.real })

    helper.compress._set_source({
        load = function()
            return fake
        end,
    })
end

--- Строки выгрузки журнала, JSON через перевод строки.
---
--- На них уровень, окно, память и стратегия сжатия дают разный выход —
--- сверено на zlib 1.2.11 (Linux) и 1.2.12 (macOS). На словах из
--- случайных букв седьмой уровень и шестой сжимают байт в байт.
---@param count integer
---@return string
function helper.rows(count)
    local rows = {}

    for index = 1, count do
        rows[index] = json.encode({
            id = index,
            name = 'storage-' .. (index * 7919 % 1000),
            state = index % 7 == 0 and 'dead' or 'alive',
            uptime = index * 13,
            lsn = index * 1000 + 7,
        })
    end

    return table.concat(rows, '\n')
end

--- Сколько места под выход у оракула, байт.
local ROOM = 4 * 1024 * 1024

--- Сжатие вызовами zlib с названными параметрами — оракул.
---
--- Шаг — вход и режим сброса одним вызовом: 2 — `Z_SYNC_FLUSH`,
--- 4 — `Z_FINISH`. Пакет подаёт вход кусками, но выход DEFLATE от нарезки
--- входа не зависит, и с оракулом он обязан сойтись байт в байт.
---@param settings { level: integer, window: integer, memory: integer, strategy: integer }
---@param steps { [1]: string, [2]: integer }[]
---@return string
function helper.replay(settings, steps)
    local library = helper.real
    local stream = ffi.new('tnt_compress_stream[1]') --[[@as any]]
    local out = ffi.new('unsigned char[?]', ROOM)

    assert(
        library.tnt_compress_deflate_init(
            stream,
            settings.level,
            8,
            settings.window,
            settings.memory,
            settings.strategy,
            library.tnt_compress_version(),
            ffi.sizeof('tnt_compress_stream')
        ) == 0
    )

    stream[0].next_out = out
    stream[0].avail_out = ROOM

    for _, step in ipairs(steps) do
        stream[0].next_in = ffi.cast('const unsigned char *', step[1])
        stream[0].avail_in = #step[1]

        library.tnt_compress_deflate(stream, step[2])
        assert(stream[0].avail_in == 0 and stream[0].avail_out > 0)
    end

    library.tnt_compress_deflate_end(stream)

    return ffi.string(out, ROOM - stream[0].avail_out)
end

--- Сжатие строки одним вызовом zlib с названными параметрами — оракул.
---@param data string
---@param settings { level: integer, window: integer, memory: integer, strategy: integer }
---@return string
function helper.reference(data, settings)
    return helper.replay(settings, { { data, 4 } })
end

--- Байты, которые zlib не сожмёт: случайные, но одни и те же от запуска
--- к запуску.
---
--- Генератор Парка — Миллера: произведение меньше 2^46 и точно в double.
--- У генератора с множителем 1103515245 произведение вылезает за 2^53,
--- младшие биты теряются, и «шум» выходит повтором, который zlib жмёт
--- вдевятеро.
---@param length integer
---@return string
function helper.noise(length)
    local bytes = {}
    local seed = 7

    for index = 1, length do
        seed = seed * 16807 % 2147483647
        bytes[index] = string.char(seed % 256)
    end

    return table.concat(bytes)
end

return helper
