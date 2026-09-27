--- Сжатие: строкой целиком и потоком по кускам.
---
--- Сжатие отказать не может — только бросить на негодный аргумент: вход
--- свой, а не чужой, и zlib сожмёт любые байты. Форматы, кусок работы
--- и уступки — `tnt.compress.stream`.

local ffi = require('ffi')

local must = require('tnt.must')

local stream_of = require('tnt.compress.stream')
local system = require('tnt.compress.system')
local zlib = require('tnt.compress.zlib')

local Module = {}

--- Уровень сжатия по умолчанию — умолчание самой zlib: на выгрузке
--- журнала он сжимает почти как девятый (13,9 % против 13,8 %) втрое
--- быстрее его (замер на 3.8: 170 МБ/с против 65).
Module.LEVEL = 6

--- Метод, память и стратегия сжатия — умолчания zlib: `Z_DEFLATED`,
--- `MAX_MEM_LEVEL` для 64-битных сборок и `Z_DEFAULT_STRATEGY`.
local METHOD = 8
local MEMORY = 8
local STRATEGY = 0

--- Бросок на кусок после конца потока.
local FINISHED = 'поток сжатия закончен: finish уже позван'

---@class TntCompressOptions Настройки сжатия
---@field format string|nil `gzip` (по умолчанию), `zlib` либо `raw`
---@field level integer|nil Уровень, 0…9; по умолчанию 6

--- Поток сжатия.
---@class TntCompressDeflater
---@field library any Библиотека zlib
---@field stream any Поток zlib; nil после `finish`
local Deflater = {}
Deflater.__index = Deflater

--- Прогоняет вход через поток сжатия.
---
--- После вызова, оставившего место в буфере, zlib забрала весь вход
--- и отдала всё, что просил режим сброса (`zlib.h`): по этому признаку
--- и кончается круг.
---@param self TntCompressDeflater
---@param input string
---@param flush integer Режим сброса последнего куска
---@return string
local function squeeze(self, input, flush)
    local stream = self.stream
    local buffer = stream_of.buffer
    local chunk = stream_of.CHUNK
    local parts = {}
    local offset = 0
    local started = false

    repeat
        local size = math.min(#input - offset, chunk)

        stream.next_in = ffi.cast(stream_of.BYTES, input) + offset
        stream.avail_in = size
        offset = offset + size

        local mode = offset == #input and flush or zlib.NO_FLUSH

        repeat
            if started then
                system.pause()
            end

            started = true
            stream.next_out = buffer
            stream.avail_out = chunk
            self.library.tnt_compress_deflate(stream, mode)
            table.insert(parts, ffi.string(buffer, chunk - stream.avail_out))
        until stream.avail_out ~= 0
    until offset == #input

    return table.concat(parts)
end

--- Кусок потока с проверками: строка и незаконченный поток.
---@param self TntCompressDeflater
---@param chunk any
---@param flush integer
---@return string
local function deflated(self, chunk, flush)
    must.at(3).string(chunk, 'кусок')

    if self.stream == nil then
        error(FINISHED, 3)
    end

    return squeeze(self, chunk, flush)
end

--- Дописывает кусок. Выход бывает и пустым: zlib копит вход, пока
--- не наберёт на блок.
---@param chunk string
---@return string
function Deflater:write(chunk)
    local packed = deflated(self, chunk, zlib.NO_FLUSH)

    return packed
end

--- Дописывает кусок и отдаёт всё сжатое к этому мигу.
---
--- Для ответа по кускам: читающий на той стороне разожмёт всё, что
--- пришло, не дожидаясь конца. Каждый сброс стоит несколько байт
--- и немного сжатия.
---@param chunk string|nil Последний кусок перед сбросом
---@return string
function Deflater:flush(chunk)
    local packed = deflated(self, chunk or '', zlib.SYNC_FLUSH)

    return packed
end

--- Дописывает последний кусок и заканчивает поток.
---@param chunk string|nil Последний кусок
---@return string
function Deflater:finish(chunk)
    local packed = deflated(self, chunk or '', zlib.FINISH)

    stream_of.close(self.stream, self.library.tnt_compress_deflate_end)
    self.stream = nil

    return packed
end

--- Заводит поток сжатия по настройкам.
---@param options any
---@param level integer Уровень вины от функции, позвавшей эту
---@return TntCompressDeflater
local function deflater_of(options, level)
    local caller = must.at(level + 1)

    caller.optional.options(options, 'настройки', { format = '?string', level = '?integer' })

    local given = options or {}
    local window = stream_of.window_of(given, level + 1)
    local strength = given.level or Module.LEVEL

    caller.between(strength, 'настройки.level', 0, 9)

    local library = zlib.library(level + 1)
    local version = library.tnt_compress_version()
    local stream = stream_of.open(function(raw, size)
        return library.tnt_compress_deflate_init(raw, strength, METHOD, window, MEMORY, STRATEGY, version, size)
    end, library.tnt_compress_deflate_end, level + 1)

    return setmetatable({ library = library, stream = stream }, Deflater)
end

--- Поток сжатия.
---@param options TntCompressOptions|nil
---@return TntCompressDeflater
function Module.new(options)
    local opened = deflater_of(options, 2)

    return opened
end

--- Сжимает строку целиком.
---@param data string
---@param options TntCompressOptions|nil
---@return string
function Module.deflate(data, options)
    must.at(2).string(data, 'данные')

    return deflater_of(options, 2):finish(data)
end

return Module
