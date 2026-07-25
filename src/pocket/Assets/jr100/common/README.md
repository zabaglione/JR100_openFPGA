# JR-100 共通アセット / Shared JR-100 assets

このディレクトリに BASIC ROM を置いてください。

Put the JR-100 BASIC ROM here.

## boot.rom

8 KiB の結合イメージです。

| オフセット | 内容 | サイズ |
|---|---|---|
| `0x0000`–`0x03FF` | キャラクタ ROM | 1 KiB |
| `0x0400`–`0x1FFF` | BASIC ROM (`E400`–`FFFF`) | 7 KiB |

ROM は同梱していません。実機から吸い出したものを利用者自身で用意してください。

The ROM is not distributed with this core. Dump it from your own hardware.
