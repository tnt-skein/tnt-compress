# tnt-compress

Сжатие gzip, zlib и DEFLATE для Tarantool фасадом поверх системной zlib:
строкой и потоком, разжатие с отказом парой и пределом от «бомбы»,
уступки между кусками работы и слой ответа для роутера.

```lua
local compress = require('tnt.compress')

local packed = compress.deflate(body)                     -- gzip, уровень 6
local text, err = compress.inflate(packed)                -- отказ парой

if text == nil and err.kind == compress.TOO_LARGE then
    -- разжатое больше предела: 16 МБ, если не сказано иначе
end

middleware.configure({ layers = { compress = compress.layer } })
```

Работу делает системная zlib через FFI — пакет даёт то, чего у неё нет.
Зависит от `tnt-must` и `tnt-external`.

## Зачем

- **Сжать в CE нечем.** Модуль `compress` есть только в Enterprise,
  среди роков сжатия нет, а `http.client` умеет лишь разжать ответ.
  zlib же есть на любом узле: пакет находит `libz.so.1` и рядом
  со статической сборкой Tarantool, где символов zlib в процессе нет.
- **Отказ парой с родом.** Разжимают чужое — тело запроса, файл копии,
  выгрузку, — и испорченное там бывает: `corrupt`, `truncated`,
  `too_large`, `failed`. Предел разжатого есть всегда: килобайт злого
  входа разжимается в гигабайт.
- **Узел не встаёт.** Сжатие — счёт в потоке событий, и между вызовами
  zlib работа уступает; внутри транзакции `box` — нет, чтобы её
  не оборвать.
- **Слой ответа.** gzip по `Accept-Encoding` с весами, `Vary`, слабая
  метка у сжатого вида, ответ по кускам остаётся потоком.

## Установка

```sh
tt rocks install tnt-compress --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-compress.git
cd tnt-compress && tt rocks make
```

## Как пользоваться

| Вызов | Что отдаёт |
|---|---|
| `deflate(данные[, { format, level }])` | сжатую строку |
| `inflate(данные[, { format, limit }])` | разжатую строку либо `nil, err` |
| `deflater(настройки)` | поток сжатия: `write`, `flush`, `finish` |
| `inflater(настройки)` | поток разжатия: `write`, `finish` |
| `layer([{ level, min_size }])` | слой ответа; он же фабрика для реестра `tnt-middleware` |
| `available()` | `true` либо `false, почему` — есть ли zlib на узле |

Форматы — `gzip` (по умолчанию), `zlib`, `raw`; уровень — 0…9, по умолчанию
6; предел разжатого — 16 МБ.

```lua
compress.inflate(compress.deflate(batch_one) .. compress.deflate(batch_two))
--> batch_one .. batch_two: gzip разжимается членами подряд, как у gzip -d

local deflater = compress.deflater()
send(deflater:flush(chunk))       -- та сторона разожмёт всё пришедшее сразу
send(deflater:finish())

local r = router.new({ entry = { compress.layer() } })
```

Данные не строкой, чужой ключ настроек, формат не из трёх, кусок после
`finish` — бросок с местом вызывающего:

```
app.lua:4: настройки.level — число от 0 до 9, а не 10
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, рок http, роутер и реестр слоёв в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (402 мутанта в семи
модулях). Выход сжатия сверен байт в байт с одним вызовом zlib
с названными параметрами; отсутствие уступок в транзакции — на временном
узле с настоящим `box`; слой — в настоящем роутере, в реестре слоёв
и на `http.server`, откуда ответ читает libcurl.

## Документ

Полное описание с обоснованием решений: [docs/compress.md](docs/compress.md).

## Лицензия

MIT.
