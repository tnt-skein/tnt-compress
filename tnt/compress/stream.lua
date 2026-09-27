--- Общее у потоков сжатия и разжатия: форматы, кусок работы, поток zlib.
---
--- Формат — обёртка вокруг одного и того же DEFLATE (RFC 1951):
---
--- * `gzip` (RFC 1952) — файлы `.gz` и `Content-Encoding: gzip`;
--- * `zlib` (RFC 1950) — то, что HTTP называет `deflate`;
--- * `raw` — DEFLATE без обёртки: zip и `permessage-deflate` у WebSocket.
---
--- Между вызовами zlib — уступка (`tnt.compress.system`): вход уходит
--- кусками по `CHUNK` байт, выход собирается в буфер того же размера.
--- Уступки нет только в транзакции.
---
--- Поток — одному файберу: два файбера, пишущие в один поток, перемешали
--- бы куски между уступками.

local ffi = require('ffi')

local must = require('tnt.must')

local zlib = require('tnt.compress.zlib')

local Module = {}

--- Форматы в порядке распространённости.
Module.FORMATS = { 'gzip', 'zlib', 'raw' }

--- Кусок работы, байт: столько входа уходит в zlib за вызов и столько
--- места под выход.
---@type integer
Module.CHUNK = 64 * 1024

--- Окно — 32 КБ, наибольшее у zlib. Прибавка 16 просит обёртку gzip,
--- знак минус — голый DEFLATE (`zlib.h`, `deflateInit2`).
local WINDOW = 15
local GZIP = 16

--- Окно по формату.
Module.WINDOWS = {
    gzip = WINDOW + GZIP,
    zlib = WINDOW,
    raw = -WINDOW,
}

--- Вход для zlib.
Module.BYTES = 'const unsigned char *'

--- Общий буфер выхода: между вызовом zlib и снятием выхода строкой
--- уступки нет, и файберам делить его не из-за чего.
Module.buffer = ffi.new('unsigned char[?]', Module.CHUNK)

--- Окно формата из настроек.
---@param options table
---@param level integer Уровень вины от функции, позвавшей эту
---@return integer
function Module.window_of(options, level)
    local format = options.format or Module.FORMATS[1]

    must.at(level + 1).one_of(format, 'настройки.format', Module.FORMATS)

    return Module.WINDOWS[format]
end

--- Заводит поток zlib.
---
--- Отказ `…Init2_` — нехватка памяти либо чужая zlib, у которой поток
--- другой длины: поломка узла, а не данные вызывающего, поэтому бросок.
---@param init fun(stream: any, size: integer): integer Вызов `…Init2_`
---@param finish any Освобождение: `deflateEnd` либо `inflateEnd`
---@param level integer Уровень вины от функции, позвавшей эту
---@return any stream
function Module.open(init, finish, level)
    -- Структура, а не массив из одной: в вызов zlib она уходит указателем
    -- на себя, и лишнего числа, которое мутант мог бы поменять, нет.
    local stream = ffi.new('tnt_compress_stream')
    local code = init(stream, ffi.sizeof(stream) --[[@as integer]])

    if code ~= zlib.OK then
        error(('zlib не завела поток: код %d'):format(code), level + 1)
    end

    -- Состояние потока zlib держит в своей памяти, и брошенный на полпути
    -- поток освобождает сборщик.
    return ffi.gc(stream, finish)
end

--- Освобождает поток zlib сразу, не дожидаясь сборщика.
---@param stream any
---@param finish fun(stream: any): integer
function Module.close(stream, finish)
    ffi.gc(stream, nil)
    finish(stream)
end

return Module
