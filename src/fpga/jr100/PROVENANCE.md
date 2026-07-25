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

| 日付 | ファイル | 変更 | 理由 |
|---|---|---|---|
| 2026-07-25 | `jr100_top.sv` | 出力ポート `dbg_bus_addr` / `dbg_bus_wdata` / `dbg_bus_we` を追加（内部の `ext_addr` / `ext_wdata` / `ext_we` をそのまま出すだけの受動タップ。挙動変更なし） | 仮想キーボードのラベル面切り替えのため、ROM の GRAPH モードフラグ（ワーク RAM `0x0014`、`docs/KEYBOARD.md`）をラッパー側からスヌープする。キー押下からの推測トラッキングは ROM がキーを処理しなかった場合にずれる不具合があった（実機で確認）。既存の `dbg_*` ポート群と同じ流儀の追加であり、MiSTer 版へもそのまま還元可能 |
