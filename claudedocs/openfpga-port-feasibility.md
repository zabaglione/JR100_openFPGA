# JR-100 MiSTer コア → Analogue Pocket (openFPGA) 移植 調査報告

- 調査日: 2026-07-25
- 調査対象: `~/jr100-core`（= github.com/zabaglione/JR100_MiSTer, HEAD `767aa73`）
- 目的: Analogue Pocket 実機で JR-100 を動かす

---

## 1. 結論

**移植は可能。** ただし「MiSTer フレームワークへの依存部分を APF（Analogue Platform Framework）へ書き直す」作業であり、
エミュレーション本体の再設計は不要。

- **そのまま流用できる**: CPU・VIA・映像・メモリ・CMT など JR-100 の中身、約 **4,300 行 / 全 4,643 行 (93%)**
- **書き直しが必要**: `JR100.sv`（328行）と `jr100_keyboard.sv`（94行, PS/2 依存）、および周辺のグルー
- **新規に書く必要がある**: APF のデータスロット I/O、仮想キーボード、JSON メタデータ、ビルド定義

作業量の実体は「新規に書く APF グルー」が支配的で、参考実装（PocketCPC）では
core_top + Pocket グルーだけで 20万行相当のファイル群になっている。JR-100 は機能が少ないぶん小さくなるが、
**HDL 本体より周辺のほうが大きくなる**という覚悟は必要。

---

## 2. 現状の JR-100_MiSTer 構成

| ファイル | 行数 | 移植時の扱い |
|---|---:|---|
| `rtl/cpu/mb8861.sv` | 1,132 | **そのまま** |
| `rtl/jr100/jr100_via.sv` | 505 | **そのまま** |
| `rtl/jr100/jr100_top.sv` | 412 | ポート I/F の一部改修 |
| `rtl/jr100/jr100_loader.sv` | 380 | **ほぼそのまま**（供給元が変わるだけ） |
| `rtl/jr100/jr100_cmt.sv` | 347 | SD ブロック I/F を要改修 |
| `rtl/jr100/jr100_bas_loader.sv` | 327 | **ほぼそのまま** |
| `rtl/jr100/jr100_saver.sv` | 241 | 書き戻し I/F を要改修 |
| `rtl/jr100/jr100_tape_buf.sv` | 219 | SD ブロック I/F を要改修 |
| `rtl/jr100/jr100_core.sv` | 196 | **そのまま** |
| `rtl/jr100/jr100_mem.sv` | 163 | **そのまま** |
| `rtl/jr100/jr100_autotype.sv` | 157 | **そのまま** |
| `rtl/jr100/jr100_video.sv` | 142 | **そのまま** |
| `rtl/jr100/jr100_keyboard.sv` | 94 | **全面差し替え**（PS/2 → USB HID + 仮想KB） |
| `JR100.sv` (emu wrapper) | 328 | **全面差し替え**（→ `core_top.sv`） |

MiSTer 依存点は `JR100.sv` に集約されている（`hps_io`、`CONF_STR`、`VGA_*`、`AUDIO_*`、`ps2_key`、
`ioctl_*`、`img_mounted`/`sd_lba`/`sd_rd`/`sd_wr`）。設計がきれいに層分けされているのは移植上かなり有利。

---

## 3. ハードウェア比較

| | MiSTer (DE10-Nano) | Analogue Pocket |
|---|---|---|
| FPGA | 5CSEBA6U23I7 / 41,910 ALM | **5CEBA4F23C8 / 18,480 ALM (49K LE)** |
| BRAM | 5,662,720 bit | 約 3,383 Kbit |
| Quartus | 17.0.2 Lite | **18.1.1 Lite**（PocketCPC 実績、`raetro/quartus:18.1` docker） |
| 基準クロック | 50 MHz | **74.25 MHz**（`clk_74a` / `clk_74b`、位相非同期） |
| ホスト | ARM HPS + Linux (`hps_io`) | **APF bridge（32bit バス、数MB/s）** |
| 出力 | VGA/HDMI（コア内にスケーラ） | **video_rgb 24bit + de/hs/vs**（スケーラは第2 FPGA 側） |
| 音声 | AUDIO_L/R 16bit | **I2S（audio_mclk/dac/lrck, 48kHz）** |
| 入力 | PS/2 キーボード + ジョイ | **パッド4系統 + Dock USB キーボード（cont3）/ マウス（cont4）** |
| ビットストリーム | `.rbf` | **`.rbf_r`（ビット反転）** |

現行の MiSTer ビルド全体は 16,922 ALM（40%）だが、その大半は MiSTer フレームワーク側（ascal, HDMI PLL,
hps_io, video_mixer, sd_card 等。DSP 33 個も主にここ）。JR-100 本体は 5CEBA4 の 18,480 ALM に収まる見込みだが、
**これは実測していない推定**であり、最初のビルドで確認すべき事項。

BRAM は明確に余裕がある。`jr100_mem.sv` の実体は
main_ram 16KiB + ext_ram 16KiB + cgram 256B + vram 1KiB + char_rom 1KiB + basic_rom 8KiB ≒ **42.25 KiB (346 Kbit)**。
テープバッファを足しても 3,383 Kbit に対して十分。SDRAM / PSRAM は不要（BRAM のみで完結）。

---

## 4. 移植作業の分解

### A. トップレベル：`emu` → `core_top`
openFPGA の `core_top.v`（675行のテンプレート）に置き換える。カートリッジ・リンクポート・PSRAM・SDRAM・SRAM の
未使用ピンを全部 tie-off し、`core_bridge_cmd` を組み込む。テンプレートは
`github.com/open-fpga/core-template` からそのまま持ってこられる。

### B. クロック / PLL
現行は 50 MHz → **57.272727 MHz**（= 4×NTSC カラーバースト、`/8` = 7.159 MHz pixel、`/64` = 894.886 kHz CPU）。
Pocket では 74.25 MHz 起点で同じ 57.272727 MHz を作り直す。

- 整数比だと `74.25 × 280/33 = 630 MHz` VCO ÷ 11 で厳密に出せるが、PFD が 2.25 MHz と低すぎる可能性がある
- Cyclone V の**フラクショナル PLL** を使えば実用上問題なく出せる（MiSTer 側も 50 MHz からフラクショナルで生成している）
- 同じ PLL から `7.159 MHz` と `7.159 MHz@90°` も出して `video_rgb_clock` / `video_rgb_clock_90` に使う

### C. 映像
`jr100_video.sv` は 448×256 total / 256×192 active / dot 7.15909 MHz / **62.4 Hz** をそのまま出している。
APF は「コアが出す任意タイミングの RGB+DE+HS+VS を受けてスケーラに渡す」方式なので、**タイミング生成はそのまま使える**。

- `video.json` の `scaler_modes` に `256×192 / aspect 4:3` を登録
- `display_modes` に `0x10`（CRT Trinitron）等を入れると Analogue 純正フィルタが使える
- OSD の表示色選択（白/緑/アンバー…8色）は `interact.json` の list 変数として移植可能

### D. 音声
`AUDIO_L/R` の 16bit 値を I2S へ。agg23 の `sound_i2s.sv`（PocketCPC も同じものを使用）をそのまま使えばよい。
別途 audio PLL が必要（`mf_audio_pll`）。JR-100 は 1bit 矩形波なので実質そのまま流し込むだけ。

### E. 入力（**最も設計判断が要る箇所**）
Pocket にキーボードは無い。実績のある構成は 2 系統併用：

1. **Dock 経由 USB キーボード**: HID boot keyboard レポートが
   `cont3_key[15:8]`（修飾キー）と `cont3_joy[31:0]` + `cont3_trig[15:0]`（同時押し 6 キー分の usage code）で届く。
   PocketCPC はこれを **PS/2 スキャンコード列に変換**して既存の MiSTer 製キーボードロジックへ流している。
   → JR-100 も同じ手が使える。`jr100_keyboard.sv`（PS/2 → 45bit マトリクス）を温存したまま、
   前段に「HID → PS/2」変換を挟むのが最小コスト。
2. **仮想キーボード（画面オーバーレイ）**: 携帯時はこれが無いと実用にならない。
   PocketCPC は Select ボタンで開くオーバーレイを HDL で実装（`cpc_virtual_keyboard_overlay.sv`）。
   JR-100 のキーマトリクスは 45 キーと小さいので、CPC より作りやすい。

注意: Dock USB キーボードは **Analogue 公式ドキュメントに明記された仕様というより、コア実装側で確立した使い方**。
PocketCPC 自身が「experimental」と明記している。

### F. ファイル I/O（ROM / PRG / BAS / CMT / SAVE）
MiSTer の `ioctl_*`（読み込み）と `img_mounted`/`sd_lba`/`sd_rd`/`sd_wr`（ブロック R/W）は APF に存在しない。
APF では：

- **読み込み**: コアが `target_dataslot_read` を発行 → ホストが bridge RAM（例 `0x60000000`）へ 1KB チャンクを書く
  → コアがバイト単位で吸い出す。PocketCPC の `pocket_dataslot_loader.sv` がほぼ雛形になる。
  - `boot.rom`（8KiB, char ROM + BASIC ROM）→ `jr100_loader` の loader ポートへ
  - `.prg` / `.bas` → 既存の `prg_download` / `bas_download` ポートへ（**そのまま繋がる**）
- **書き戻し**: `target_dataslot_write` で書込み可能スロットへ 1KB チャンク単位で送出。
  - BASIC の SAVE（`jr100_saver.sv`）と `.cmt` 録音（`jr100_cmt` / `jr100_tape_buf`）が該当
  - 現行は 512B セクタ + `sd_lba`/`sd_ack` ハンドシェイク前提なので、**ここは再設計が必要**
- スロット定義は `data.json`（最大 32 スロット、拡張子・サイズ・required/deferload を指定）

### G. OSD → `interact.json`
`CONF_STR` の各項目を `interact.json` の変数（list / check / action）に置き換え、
書き込み先の bridge アドレスをコア内レジスタにマップする（PocketCPC の `pocket_bridge_regs.sv` が雛形）。

| 現行 CONF_STR | openFPGA での置き換え |
|---|---|
| `F0,rom` / `F1,prg` / `F2,bas` | `data.json` のデータスロット |
| `S0,prg` (Mount Save) / `S1,cmt` (Mount Tape) | 同上（書込み可能スロット） |
| `T[3] Save BASIC` / `T[4] Tape Play` | `interact.json` の `type: action` |
| `O[8:6] Display color` | `type: list`（8択） |
| `O[2] Extended RAM` / `O[5] Autostart` | `type: check` |
| `O[122:121] Aspect ratio` | `video.json` の `scaler_modes` 複数登録 |
| `R[0] Reset` | `type: action` |

### H. ビルド / パッケージング
- Quartus **18.1.1 Lite**、device `5CEBA4F23C8`
- 出力 `.rbf` を**ビット反転**して `bitstream.rbf_r` にする（PocketCPC の `scripts/reverse_rbf_bits.py`）
- SD カードへの配置: `Cores/<author>.<name>/`, `Platforms/`, `Assets/`
- 現行の GitHub Actions（Quartus 17.0）は作り直しになる

---

## 5. リスクと未確認事項

| # | 項目 | 深刻度 | 内容 |
|---|---|---|---|
| 1 | **62.4 Hz のリフレッシュレート** | **高** | JR-100 の映像は NTSC 非準拠の 62.4 Hz。Pocket スケーラの許容範囲が公式ドキュメントに明記されておらず、既存コアも概ね 50〜60 Hz。**実機で確認するまで未知**。NG なら (a) 60 Hz 付近へタイミング調整（実機忠実性を犠牲）か (b) フレームバッファを挟む、の判断が要る |
| 2 | ロジック量 | 中 | 5CEBA4 は MiSTer 側の半分以下（18,480 ALM）。JR-100 本体は収まる見込みだが未実測。最初に「コアだけ通す」ビルドで確認すべき |
| 3 | CMT / SAVE の書き戻し | 中 | セクタ単位ハンドシェイクから APF のチャンク転送への作り直し。CMT は再生中にストリーミングするので、バッファ設計を見直す必要がある |
| 4 | Dock USB キーボード | 中 | 非公式仕様、experimental。Dock 必須なので携帯時は仮想キーボードが実質必須 |
| 5 | 仮想キーボード実装 | 中 | HDL でオーバーレイを描く必要がある。JR-100 の映像パイプラインに合成段を足す |
| 6 | Analogue 公式ドキュメントの薄さ | 低〜中 | video/hardware の詳細ページが 404 で取れず、実質は既存コアのソースが一次資料。PocketCPC / Pocket ZX Spectrum を読むのが最短 |
| 7 | ライセンス | 低 | 現行 GPL-2.0。openFPGA コアも GPL で配布されている前例多数（PocketCPC も同様）。問題なし |

---

## 6. 推奨する進め方

段階ごとに「実機で動くもの」を作る前提。

1. **Phase 0 — 足場**: core-template を clone、`5CEBA4F23C8` / Quartus 18.1 でテンプレートのまま
   ビルド〜`.rbf_r` 生成〜Pocket 実機起動まで通す。**ここでツールチェーンを固める**
2. **Phase 1 — 映像だけ**: PLL（57.2727 / 7.159 / 7.159@90）を組み、`jr100_top` を繋いで
   ROM 無しでも画面が出る状態に。**リスク #1（62.4Hz）をここで潰す**
3. **Phase 2 — ROM ロード**: `data.json` に `boot.rom` スロット、dataslot loader を実装。BASIC 起動画面まで
4. **Phase 3 — 入力**: パッド → ジョイスティック、仮想キーボード、Dock USB キーボード
5. **Phase 4 — 音声**: I2S 接続
6. **Phase 5 — ファイル**: `.prg` / `.bas` ロード（既存ポートにほぼ直結）
7. **Phase 6 — 書き戻し**: BASIC SAVE、`.cmt` 再生・録音
8. **Phase 7 — 仕上げ**: `interact.json`（表示色・拡張RAM・オートスタート）、Platform 画像、配布パッケージ

Phase 2 まで到達すれば「Pocket で JR-100 の BASIC が起動する」状態になる。

---

## 7. 参考リファレンス

| リソース | 用途 |
|---|---|
| [open-fpga/core-template](https://github.com/open-fpga/core-template) | `core_top.v` / `core_bridge_cmd.v` / APF 一式の出発点 |
| [stilvoid/PocketCPC](https://github.com/stilvoid/PocketCPC) | **最重要**。MiSTer 8bit ホビーPC → Pocket の完動例。仮想KB・Dock USB KB・テープ・ディスク・書き戻し・Docker ビルド・パッケージング全部入り |
| [dave18/OpenFPGA_ZX-Spectrum](https://github.com/dave18/OpenFPGA_ZX-Spectrum) | PocketCPC が参照した Pocket 統合の元ネタ |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | `sound_i2s.sv` / `data_loader.sv` / `data_unloader.sv` / `sync_fifo.sv`、wiki（Clocks / Video / Porting / Quartus） |
| [Analogue Developer Docs](https://www.analogue.co/developer/docs/overview) | core.json / video.json / data.json 等の正式定義（一部ページは要ナビゲーション） |
| [Bus Communication](https://www.analogue.co/developer/docs/bus-communication) | bridge の 32bit アドレス空間、`0xF8xxxxxx` 予約領域 |
| [Video Modes on Analogue openFPGA cores](https://drewler.net/blog/2023/12/analogue-openfpga-video-modes) | `display_modes` の実例 |

---

## 8. 一言まとめ

JR-100 コアは**エミュ本体と MiSTer 依存部がきれいに分離されている**ため、移植の難所は
「JR-100 をどう作るか」ではなく「APF でファイル I/O とキーボードをどう作るか」に集中する。
PocketCPC という直近の完動リファレンスがあるので設計は追随でき、
**最大の未知数はリフレッシュレート 62.4 Hz が Pocket のスケーラで通るか**の一点。
これは Phase 1 で早期に確認すべき。
