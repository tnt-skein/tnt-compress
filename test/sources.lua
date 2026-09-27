--- Модули пакета в порядке зависимостей.
---
--- Одним списком для своих проверок и для соседей, которые грузят сжатие
--- из исходников заново на каждую проверку. Помощник пакета грузит его
--- уже при подключении, и соседям список у него не взять; а списки,
--- переписанные у каждого соседа, разъезжались бы с пакетом молча.
return {
    'tnt.compress.system',
    'tnt.compress.zlib',
    'tnt.compress.failure',
    'tnt.compress.stream',
    'tnt.compress.deflater',
    'tnt.compress.inflater',
    'tnt.compress.layer',
    'tnt.compress',
}
