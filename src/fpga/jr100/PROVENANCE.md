# JR-100 RTL の出自 / Provenance

このディレクトリのファイルは [JR100_MiSTer](https://github.com/zabaglione/JR100_MiSTer) から
そのままコピーしたものです。**原則としてこのポートでは改変しません。**

| 項目 | 値 |
|---|---|
| 取得元 | `https://github.com/zabaglione/JR100_MiSTer` |
| リビジョン | `767aa73f6c9a80eb11b6e287ddbd3a5bddccc345` |
| 取得日 | 2026-07-25 |
| ライセンス | GPL-2.0-or-later |

## 元パス

| このリポジトリ | JR100_MiSTer |
|---|---|
| `mb8861.sv` | `rtl/cpu/mb8861.sv` |
| `jr100_*.sv` | `rtl/jr100/jr100_*.sv` |

`jr100_keyboard.sv` は PS/2 スキャンコードを 45 ビットのキーマトリクスへ変換する。
Pocket 側では前段に USB HID → PS/2 変換と仮想キーボードを置き、このモジュール自体は
無改変で使う（`AGENTS.md` §5.2）。

## 改変した場合

変更したファイルと理由をここに追記し、移植元へフィードバックできる形にすること。

（現時点で改変なし）
