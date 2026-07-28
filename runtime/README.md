# Источник runtime

Git-репозиторий не хранит сторонние runtime-бинарники.

Скачайте официальный
[`zapret-win-bundle`](https://github.com/bol-van/zapret-win-bundle) и распакуйте
его в любое место внутри этого каталога. Сборщик релиза выполняет рекурсивный
поиск и предпочитает стандартную структуру zapret2.

Для релиза нужны:

- `winws2.exe`;
- `WinDivert.dll`;
- `WinDivert64.sys`;
- `cygwin1.dll`;
- `zapret-lib.lua`;
- `zapret-antidpi.lua`.

Источник, дата скачивания и SHA-256 локального upstream-архива записаны в
`SOURCE.json`.

Чтобы указать runtime вне этого каталога:

```powershell
.\zapretctl.cmd runtime path C:\tools\zapret-winws\winws2.exe
```

Условия сторонних проектов перечислены в
[`THIRD-PARTY-LICENSES.txt`](../THIRD-PARTY-LICENSES.txt).
