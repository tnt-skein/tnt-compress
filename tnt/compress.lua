--- Сжатие фасадом поверх системной zlib: строкой, потоком и слоем ответа.
---
---     local compress = require('tnt.compress')
---
---     local packed = compress.deflate(body)                     -- gzip, уровень 6
---     local text, err = compress.inflate(packed)                -- отказ парой
---
---     if text == nil and err.kind == compress.TOO_LARGE then
---         -- разжатое больше предела: 16 МБ, если не сказано иначе
---     end
---
---     local deflater = compress.deflater()                      -- по кускам
---     local head = deflater:write(chunk)                        -- бывает и пустым
---     local tail = deflater:finish()
---
---     middleware.configure({ layers = { compress = compress.layer } })
---
--- Что есть готового, сверено запуском на 3.8: `http.client` разжимает
--- ответ сам (`accept_encoding`, у `tnt-http` по умолчанию `gzip, deflate`),
--- а сжать строку в CE нечем — модуль `compress` только в Enterprise,
--- среди роков `rocks.tarantool.org` сжатия нет. Работу делает системная
--- zlib через FFI (`tnt.compress.zlib`), пакет даёт то, чего у неё нет:
---
--- 1. **Отказ парой с родом** у разжатия: `corrupt`, `truncated`,
---    `too_large`, `failed` (`tnt.compress.failure`), и предел разжатого
---    по умолчанию — от «бомбы».
--- 2. **Уступки** между кусками работы: сжатие — счёт в потоке событий,
---    и сотня мегабайт без уступок держала бы узел секунду.
--- 3. **Слой `compress`** для роутера: gzip по `Accept-Encoding`, `vary`,
---    сжатие ответа по кускам со сбросом (`tnt.compress.layer`).
---
--- Негодный аргумент — бросок на строку вызывающего. Подробно —
--- `docs/compress.md`.

local deflater = require('tnt.compress.deflater')
local failure = require('tnt.compress.failure')
local inflater = require('tnt.compress.inflater')
local layer = require('tnt.compress.layer')
local stream = require('tnt.compress.stream')
local system = require('tnt.compress.system')
local zlib = require('tnt.compress.zlib')

local Module = {}

--- Форматы: `gzip`, `zlib`, `raw`.
Module.FORMATS = stream.FORMATS

--- Уровень сжатия по умолчанию.
Module.LEVEL = deflater.LEVEL

--- Предел разжатого по умолчанию, байт.
Module.LIMIT = inflater.LIMIT

--- Тело короче этого, байт, слой не сжимает.
Module.MIN_SIZE = layer.MIN_SIZE

--- Не сжатые данные либо испорченные.
Module.CORRUPT = failure.CORRUPT

--- Поток оборвался.
Module.TRUNCATED = failure.TRUNCATED

--- Разжатое больше предела.
Module.TOO_LARGE = failure.TOO_LARGE

--- Отказала сама zlib.
Module.FAILED = failure.FAILED

Module.deflate = deflater.deflate
Module.inflate = inflater.inflate
Module.deflater = deflater.new
Module.inflater = inflater.new

Module.layer = layer.new

Module.available = zlib.available

--- Подменяет средства пакета: загрузчик библиотеки, уступку и признак
--- транзакции. Только для проверок.
Module._set_source = system._set_source

return Module
