--- Проверки фасада: действия и имена на своих местах.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local compress = helper.compress

local g = t.group('tnt.compress')

g.test_every_action_is_in_place = function()
    t.assert_is(compress.deflate, helper.deflater.deflate)
    t.assert_is(compress.inflate, helper.inflater.inflate)
    t.assert_is(compress.deflater, helper.deflater.new)
    t.assert_is(compress.inflater, helper.inflater.new)
    t.assert_is(compress.layer, helper.layer.new)
    t.assert_is(compress.available, helper.zlib.available)
    t.assert_is(compress._set_source, helper.system._set_source)
end

g.test_every_name_is_in_place = function()
    t.assert_is(compress.FORMATS, helper.stream.FORMATS)
    t.assert_equals(compress.LEVEL, helper.deflater.LEVEL)
    t.assert_equals(compress.LIMIT, helper.inflater.LIMIT)
    t.assert_equals(compress.MIN_SIZE, helper.layer.MIN_SIZE)
    t.assert_equals(compress.CORRUPT, helper.failure.CORRUPT)
    t.assert_equals(compress.TRUNCATED, helper.failure.TRUNCATED)
    t.assert_equals(compress.TOO_LARGE, helper.failure.TOO_LARGE)
    t.assert_equals(compress.FAILED, helper.failure.FAILED)
end
