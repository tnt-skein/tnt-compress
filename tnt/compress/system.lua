--- Внешние зависимости пакета: всё, чем он трогает систему.
---
--- Одно гнездо на весь пакет: поиск библиотеки, уступка и признак
--- транзакции нужны и сжатию, и разжатию, и проверка, подменившая одно
--- у одного модуля, не должна молча оставить настоящее у соседа.
---
--- `load` подменяется затем, чтобы увидеть узел без zlib и отказ самой
--- библиотеки — нехватку памяти, которой на исправной машине не вызвать.

local ffi = require('ffi')
local fiber = require('fiber')
local external = require('tnt.external')

---@class TntCompressSource Средства пакета
---@field load fun(name: string): any Загрузка библиотеки, как `ffi.load`
---@field yield fun() Уступка
---@field in_txn fun(): boolean Идёт ли транзакция box

---@class TntCompressSystem
---@field _set_source fun(replacement: table|nil) Подмена средств — для проверок; ставит её `external.install`
local Module = {}

--- Действующие средства.
---
--- До `box.cfg` транзакции не бывает, а само обращение к `box.is_in_txn`
--- там бросает «Please call box.cfg{} first» — отсюда проверка
--- `type(box.cfg)`.
---@type fun(): TntCompressSource
Module.current = external.install(Module, {
    load = ffi.load,
    yield = fiber.yield,

    in_txn = function()
        return type(box.cfg) ~= 'function' and box.is_in_txn()
    end,
})

--- Уступает управление между порциями работы — вне транзакции.
---
--- Сжатие идёт в потоке событий: zlib — это счёт, а не ввод-вывод, и пула
--- нитей под него у Tarantool нет. Мегабайт на шестом уровне — около 6 мс,
--- на девятом — около 16 мс (замер на 3.8), и без уступок сжатие выгрузки
--- в сотню мегабайт стояло бы весь узел больше секунды. Внутри транзакции
--- memtx уступка её оборвала бы, поэтому там работа идёт без уступок.
function Module.pause()
    local current = Module.current() --[[@as TntCompressSource]]

    if not current.in_txn() then
        current.yield()
    end
end

return Module
