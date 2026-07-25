# JR-100 openFPGA コア 開発規約

- 版: 1.0（2026-07-25）
- 対象: Analogue Pocket / openFPGA（APF）
- 移植元: `../jr100-core`（= [JR100_MiSTer](https://github.com/zabaglione/JR100_MiSTer)）

## 1. 目的

MiSTer 向けに完成している JR-100 コアを Analogue Pocket で動かす。
**エミュレーション本体は再設計しない。** MiSTer フレームワーク依存部だけを APF へ置き換える。

成果物:

- Pocket が読み込む `bitstream.rbf_r`（ビット反転済み）
- `Cores/` `Platforms/` `Assets/` を含む配布パッケージ
- ROM 入手・配置と操作方法を説明する README

## 2. ターゲットハードウェア

| 項目 | 値 |
|---|---|
| FPGA | Cyclone V `5CEBA4F23C8`（49,000 LE = 18,480 ALM、BRAM 約 3,383 Kbit） |
| Quartus | Prime **18.1.1 Lite**（コンテナ `raetro/quartus:18.1`） |
| 基準クロック | `clk_74a` / `clk_74b` = 74.25 MHz（相互に位相非同期） |
| 外部メモリ | SDRAM 512Mbit / PSRAM 64Mbit×2 / SRAM 1Mbit（**本コアでは未使用**、全て tie-off） |
| 映像 | `video_rgb[23:0]` + `video_de` / `video_hs` / `video_vs` / `video_skip`、`video_rgb_clock` と `video_rgb_clock_90` |
| 音声 | I2S（`audio_mclk` / `audio_dac` / `audio_lrck`）48 kHz |
| 入力 | `cont1..4_key` / `_joy` / `_trig`。Dock USB キーボードは **cont3**、マウスは cont4 |
| ホスト通信 | bridge（32bit アドレス空間、数 MB/s、`0xF8xxxxxx` はフレームワーク予約） |
| ファームウェア | 実機は 2.6。`core.json` の `version_required` は 2.2 とする |

## 3. JR-100 側の確定仕様（移植元から継承）

MiSTer 版 `AGENTS.md` の定義をそのまま引き継ぐ。ここでは移植に直接効く数値のみ再掲する。

| 項目 | 値 |
|---|---|
| システムクロック | 57.272727 MHz（= 4×NTSC カラーバースト = 14.31818×4） |
| ピクセルクロック | システム / 8 = **7.159091 MHz** |
| CPU クロック | システム / 64 = **894.886 kHz** |
| 画面 | 448×256 total、**256×192 active**、H sync 64 dot、V sync 8 line |
| リフレッシュ | **62.4 Hz**（NTSC 非準拠。実機の合成映像出力そのもの） |
| メモリ | main RAM 16 KiB / 拡張 RAM 16 KiB / CGRAM 256 B / VRAM 1 KiB / char ROM 1 KiB / BASIC ROM 8 KiB ≒ 42.25 KiB |
| キーボード | 45 キーマトリクス（`key_matrix[44:0]`） |
| ジョイスティック | CC02、bit0=right / 1=left / 2=up / 3=down / 4=fire、**active high** |
| カセット | 600 baud FSK（1200Hz / 2400Hz） |

## 4. ディレクトリ構成

```
src/fpga/apf/      Analogue 提供の APF 一式（core-template 由来、改変しない）
src/fpga/core/     Pocket 固有のグルー（core_top.sv, PLL, dataslot, 入力, 仮想KB）
src/fpga/jr100/    移植元からコピーした JR-100 本体 RTL（原則改変しない）
src/pocket/        SD カードに配置する JSON / アセット
scripts/           ビルド・パッケージング用スクリプト
docs/              開発ドキュメント（PLAN.md ほか）
claudedocs/        調査レポート
```

## 5. 移植方針

### 5.1 改変してよい範囲

- `src/fpga/core/` — Pocket 固有の新規コード。自由に書く
- `src/fpga/jr100/` — **原則改変しない。** 変更が必要な場合は理由を docs に記録し、
  移植元（`../jr100-core`）へフィードバックできる形にする
- `src/fpga/apf/` — **改変しない。** Analogue のフレームワーク更新に追従できなくなるため

### 5.2 MiSTer I/F → APF 対応表

| MiSTer | APF での置き換え |
|---|---|
| `hps_io` + `CONF_STR` | `core_bridge_cmd` + `interact.json` + bridge レジスタ |
| `ioctl_download` / `ioctl_wr` / `ioctl_addr` / `ioctl_dout` | `target_dataslot_read` → bridge RAM(`0x60000000`) → 1KB チャンク展開 |
| `img_mounted` / `sd_lba` / `sd_rd` / `sd_wr` / `sd_ack` | `target_dataslot_read` / `target_dataslot_write`（1KB チャンク） |
| `ps2_key[10:0]` | Dock USB HID → PS/2 変換、または仮想キーボード |
| `joystick_0` | `cont1_key[15:0]` |
| `VGA_R/G/B` `VGA_DE` `VGA_HS` `VGA_VS` `CE_PIXEL` | `video_rgb` `video_de` `video_hs` `video_vs` + 専用 `video_rgb_clock` |
| `AUDIO_L` / `AUDIO_R` | `sound_i2s.sv` → `audio_mclk` / `audio_dac` / `audio_lrck` |
| `CLK_50M` | `clk_74a` |
| `.rbf` | `.rbf_r`（ビット反転） |

### 5.3 クロックドメイン

- bridge / dataslot / コントローラ入力は **`clk_74a` 同期**
- JR-100 本体は **57.272727 MHz 同期**
- 両者を跨ぐ信号は必ず `synch_3`（多段同期）か FIFO を通す。**素通し禁止**

## 6. 参照実装

| リポジトリ | 用途 |
|---|---|
| [open-fpga/core-template](https://github.com/open-fpga/core-template) | APF 一式、`core_top.v` / `core_bridge_cmd.v` の出発点 |
| [stilvoid/PocketCPC](https://github.com/stilvoid/PocketCPC) | **主参照。** MiSTer 8bit ホビーPC → Pocket の完動例。仮想KB / Dock USB KB / テープ / 書き戻し / Docker ビルド / パッケージング |
| [dave18/OpenFPGA_ZX-Spectrum](https://github.com/dave18/OpenFPGA_ZX-Spectrum) | PocketCPC が参照した Pocket 統合の元ネタ |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | `sound_i2s.sv` / `sync_fifo.sv` / データローダ、wiki |
| [Analogue Developer Docs](https://www.analogue.co/developer/docs/overview) | JSON 定義の正式仕様 |

## 7. 検証方針

- **移植元との等価性**: JR-100 本体 RTL は改変しないので、MiSTer 版で通っているロックステップ検証を再実施しない。
  改変した場合のみ移植元のテストを回す
- **実機検証が必須の項目**: 映像（62.4 Hz が通るか）、音声、入力、ファイル入出力、SD 書き戻し
- **合成レポートの確認**: ビルドごとに ALM / BRAM 使用率と timing slack を記録する。
  5CEBA4 は MiSTer の DE10-Nano より小さいので、リソース逼迫を早期に検知する

## 8. ライセンス

- 本コア: **GPL-2.0-or-later**（移植元を継承）
- `src/fpga/apf/` は Analogue 提供コード。同梱条件に従う
- PocketCPC / agg23 utils から取り込んだコードは各ファイル冒頭に出典と原著者を明記する
- **ROM は同梱しない**
