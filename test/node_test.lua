--- Проверки на временном узле с настоящим `box`.
---
--- В процессе проверок `box` не настроен, и транзакций там не бывает.
--- Что сжатие внутри транзакции не уступает, видно только на узле, и рядом
--- стоит отрицательный контроль: уступка обрывает транзакцию, и узнать
--- об этом можно только на фиксации.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.node_group('tnt.compress.node')

g.before_each(function()
    -- Спейс для записи в транзакции: каждой проверке — пустой.
    g.server:exec(function()
        local data = box.schema.space.create('data', { if_not_exists = true })

        data:create_index('pk', { if_not_exists = true })
        data:truncate()
    end)
end)

g.test_inside_a_transaction_the_work_does_not_yield = function()
    local outcome = g.server:exec(function()
        local compress = require('tnt.compress')
        local body = string.rep('узел жив\n', 100000)

        box.begin()
        box.space.data:replace({ 1 })

        local packed = compress.deflate(body)
        local unpacked = compress.inflate(packed)

        box.space.data:replace({ 2, packed })

        local committed, err = pcall(box.commit)

        return { same = unpacked == body, committed = committed, err = tostring(err) }
    end)

    t.assert_equals(outcome, { same = true, committed = true, err = 'nil' })
end

g.test_outside_a_transaction_the_work_yields_on_the_node = function()
    local ticks = g.server:exec(function()
        local compress = require('tnt.compress')
        local fiber = require('fiber')
        local count, stopped = 0, false

        fiber.new(function()
            while not stopped do
                count = count + 1
                fiber.yield()
            end
        end)

        compress.deflate(string.rep('a', 4 * 65536))
        stopped = true

        return count
    end)

    t.assert_ge(ticks, 3)
end

g.test_a_yield_inside_a_transaction_aborts_it = function()
    -- Отрицательный контроль: сжатие с уступкой само не бросает, а падает
    -- уже фиксация.
    local outcome = g.server:exec(function()
        local compress = require('tnt.compress')

        compress._set_source({
            in_txn = function()
                return false
            end,
        })

        box.begin()
        box.space.data:replace({ 3 })

        local packed = pcall(compress.deflate, string.rep('a', 4 * 65536))
        local committed, err = pcall(box.commit)

        compress._set_source(nil)

        return { packed = packed, committed = committed, err = tostring(err) }
    end)

    t.assert_equals(outcome.packed, true)
    t.assert_equals(outcome.committed, false)
    t.assert_str_contains(outcome.err, 'Transaction has been aborted by a fiber yield')
end
