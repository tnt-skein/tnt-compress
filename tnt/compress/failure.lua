--- Отказ разжатия: таблица с родом, которая читается и как строка.
---
--- Разжимают чужое — тело запроса, файл копии, выгрузку, пришедшую
--- по сети, — и испорченное там «так бывает». Вызывающему нужно одно:
--- что случилось, словом, по которому можно решать. Родов четыре:
---
--- * `corrupt` — это не сжатые данные либо они испорчены: чужой заголовок,
---   несошедшаяся сумма, лишние байты после конца потока;
--- * `truncated` — поток оборвался: вход кончился раньше конца сжатого;
--- * `too_large` — разжатое вышло больше предела: так выглядит
---   «бомба», килобайт, разжимающийся в гигабайт;
--- * `failed` — zlib отказала сама: не хватило памяти.
---
--- Строкой отказ читается целиком: `tostring(err)`, `'причина: ' .. err`
--- и `json.encode` дают текст «что случилось: почему».

local Module = {}

--- Поведение всех отказов: в склейке, строкой и в JSON они — свой текст,
--- как у отказов `tnt-fs` и `tnt-process`.
local Failure = {
    __concat = function(left, right)
        return tostring(left) .. tostring(right)
    end,
}

---@param failure TntCompressFailure
---@return string
function Failure.__tostring(failure)
    return failure.message
end

Failure.__serialize = Failure.__tostring

--- Не сжатые данные либо испорченные.
Module.CORRUPT = 'corrupt'

--- Поток оборвался.
Module.TRUNCATED = 'truncated'

--- Разжатое больше предела.
Module.TOO_LARGE = 'too_large'

--- Отказала сама zlib.
Module.FAILED = 'failed'

---@class TntCompressFailure Отказ разжатия
---@field kind string Род: corrupt, truncated, too_large либо failed
---@field message string Что случилось и почему — его и отдаёт `tostring`

--- Отказ с родом и текстом.
---@param kind string
---@param message string
---@return TntCompressFailure
local function new(kind, message)
    return setmetatable({ kind = kind, message = message }, Failure)
end

--- Не сжатые данные либо испорченные.
---@param reason string Почему, словами zlib либо своими
---@return TntCompressFailure
function Module.corrupt(reason)
    return new(Module.CORRUPT, 'сжатые данные испорчены: ' .. reason)
end

--- Поток оборвался раньше конца.
---@return TntCompressFailure
function Module.truncated()
    return new(
        Module.TRUNCATED,
        'сжатые данные оборваны: вход кончился раньше конца потока'
    )
end

--- Разжатое больше предела.
---@param limit number Предел, байт
---@return TntCompressFailure
function Module.too_large(limit)
    return new(Module.TOO_LARGE, ('разжатое больше предела в %d байт'):format(limit))
end

--- Отказала сама zlib.
---@param reason string
---@return TntCompressFailure
function Module.failed(reason)
    return new(Module.FAILED, 'zlib отказала: ' .. reason)
end

return Module
