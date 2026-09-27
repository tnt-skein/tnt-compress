--- Проверки отказа разжатия: род и текст.

local t = require('luatest')
local json = require('json')

local helper = dofile('test/helper.lua')

local failure = helper.failure

local g = t.group('tnt.compress.failure')

g.test_the_kinds_are_named = function()
    t.assert_equals(failure.CORRUPT, 'corrupt')
    t.assert_equals(failure.TRUNCATED, 'truncated')
    t.assert_equals(failure.TOO_LARGE, 'too_large')
    t.assert_equals(failure.FAILED, 'failed')
end

g.test_each_failure_has_its_kind_and_text = function()
    t.assert_equals(failure.corrupt('incorrect header check'), {
        kind = 'corrupt',
        message = 'сжатые данные испорчены: incorrect header check',
    })
    t.assert_equals(failure.truncated(), {
        kind = 'truncated',
        message = 'сжатые данные оборваны: вход кончился раньше конца потока',
    })
    t.assert_equals(failure.too_large(1024), {
        kind = 'too_large',
        message = 'разжатое больше предела в 1024 байт',
    })
    t.assert_equals(failure.failed('не хватило памяти'), {
        kind = 'failed',
        message = 'zlib отказала: не хватило памяти',
    })
end

g.test_a_failure_reads_as_its_text = function()
    local refused = failure.truncated()
    local text =
        'сжатые данные оборваны: вход кончился раньше конца потока'

    t.assert_equals(tostring(refused), text)
    t.assert_equals('копия: ' .. refused, 'копия: ' .. text)
    t.assert_equals(refused .. '!', text .. '!')
    t.assert_equals(json.encode({ err = refused }), json.encode({ err = text }))
end
