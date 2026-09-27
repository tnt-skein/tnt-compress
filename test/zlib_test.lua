--- Проверки поиска системной zlib.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local compress = helper.compress
local zlib = helper.zlib

local g = t.group('tnt.compress.zlib')

g.after_each(helper.restore)

--- Загрузчик, который помнит имена и находит библиотеку только под одним.
---@param found string|nil Имя, под которым библиотека есть
---@return fun(name: string): any load
---@return string[] asked
local function loader(found)
    local asked = {}

    return function(name)
        table.insert(asked, name)

        if name ~= found then
            error(('%s: cannot open shared object file'):format(name), 0)
        end

        return helper.real
    end,
        asked
end

g.test_the_library_is_looked_for_by_name_then_by_soname = function()
    t.assert_equals(zlib.NAMES, { 'z', 'libz.so.1' })

    -- Под Linux без пакета разработчика `libz.so` нет, а `libz.so.1` есть.
    local load, asked = loader('libz.so.1')

    helper.compress._set_source({ load = load })

    t.assert_equals({ compress.available() }, { true, nil })
    t.assert_equals(asked, { 'z', 'libz.so.1' })
    t.assert_equals(compress.inflate(compress.deflate('данные')), 'данные')

    -- Найденная библиотека запоминается: второго поиска нет.
    compress.deflate('ещё')
    t.assert_equals(asked, { 'z', 'libz.so.1' })
end

g.test_the_first_name_found_is_taken = function()
    local load, asked = loader('z')

    helper.compress._set_source({ load = load })

    t.assert_equals({ compress.available() }, { true, nil })
    t.assert_equals(asked, { 'z' })
end

g.test_a_node_without_zlib_says_why = function()
    local load, asked = loader(nil)

    helper.compress._set_source({ load = load })

    t.assert_equals({ compress.available() }, {
        false,
        'нет системной библиотеки zlib: z: cannot open shared object file;'
            .. ' libz.so.1: cannot open shared object file',
    })

    -- Ненайденная не запоминается: поставят библиотеку — найдётся.
    compress.available()
    t.assert_equals(#asked, 4)
end

g.test_the_real_library_is_there = function()
    local ffi = require('ffi')

    t.assert_equals({ compress.available() }, { true, nil })
    t.assert_equals(ffi.string(zlib.library(1).tnt_compress_version()), ffi.string(helper.real.tnt_compress_version()))
end

g.test_the_declarations_survive_a_second_load = function()
    -- Проверки грузят исходники заново: объявление структуры второй раз
    -- уронило бы `ffi.cdef` «attempt to redefine».
    local again = helper.load_again()

    t.assert_equals(again.inflate(again.deflate('снова')), 'снова')
end

g.test_the_codes_are_those_of_zlib_h = function()
    t.assert_equals(zlib.OK, 0)
    t.assert_equals(zlib.STREAM_END, 1)
    t.assert_equals(zlib.MEM_ERROR, -4)
    t.assert_equals(zlib.BUF_ERROR, -5)
    t.assert_equals(zlib.NO_FLUSH, 0)
    t.assert_equals(zlib.SYNC_FLUSH, 2)
    t.assert_equals(zlib.FINISH, 4)
end
