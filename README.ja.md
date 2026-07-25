# JR-100 for Analogue Pocket (openFPGA)

*This is the Japanese translation; the English [README.md](README.md) is
authoritative.*

松下電器（ナショナル）**JR-100**（1981年）を Analogue Pocket の openFPGA 向けに
再実装したコアです。

エミュレーション本体は [JR100_MiSTer](https://github.com/zabaglione/JR100_MiSTer)
から無改変で移植しています。MiSTer 版は参照エミュレータ
[pyjr100emu](https://github.com/zabaglione/pyjr100emu) との命令境界ロックステップで
検証済みです。

> **状態: 開発中。** 実機で BASIC の起動を確認済み。入力・音声・ファイル I/O を
> 実装中です。実装計画と進捗は [docs/PLAN.md](docs/PLAN.md) を参照してください。

## 機能

MiSTer 版から引き継ぐもの:

- MB8861H CPU（MC6800 互換 + 独自 5 命令）
- R6522 VIA（サイクル単位）
- 32×24 キャラクタ表示、ユーザー定義グリフ（CGRAM / 共有 VRAM グリフ）
- 実機準拠のビデオタイミングを内部で維持: ドットクロック 7.15909 MHz、62.4 Hz、
  NTSC 非準拠の独自同期
- BEEP 音声（帯域制限済み）
- 実 ROM の `LOAD`/`SAVE` に対応する仮想カセットデッキ（600 baud FSK）
- 拡張 RAM 16 KiB（任意）

Pocket 固有:

- 出力段は 1bpp フレームバッファで分離（スケーラへは実績のある 320×240@60Hz、
  マシン内部は実機タイミングのまま）
- 実機の 45 キー配列を踏襲した仮想キーボード
  （Select で開閉、十字キー移動、A=押下、B=SPACE、X=RETURN、L1=SHIFT、R1=CTL）
- Analogue Dock 経由の USB キーボード（HID をキーマトリクスへ直接デコード）

## ビルド

**GitHub Actions（`build-core` ワークフロー）が主のビルド経路です。** コンテナ内の
Quartus Prime 18.1.1 Lite で合成し、SD カードにそのまま置ける `build/package/` を
アーティファクトとして出力します。

ローカルでも同じスクリプトで合成できますが、Apple Silicon では x86 エミュレーション
経由になり実用的な速度が出ません。最小限の確認用途に留めてください。

```bash
make build          # コンテナで合成（scripts/build_core.sh）
make fetch          # 代わりに最新 CI 成果物を取得
make package        # SD レイアウトを build/package/ に組む
make dist           # 配布 zip を dist/ に作る
```

SD カードへの導入:

```bash
make install POCKET_SD="/Volumes/YOUR_SD"
```

Pocket の `Tools > Developer > USB SD Access` を有効にすると、microSD を抜かずに
USB-C 経由でマウントできます。

## ROM について

BASIC ROM は同梱していません。実機から吸い出したものを
`Assets/jr100/common/boot.rom` に配置してください。8 KiB のイメージで、
`0x0000-0x03FF` がキャラクタ ROM、`0x0400-0x1FFF` が BASIC ROM です
（MiSTer 版と同じ `boot.rom`）。

## ライセンス

GPL-2.0-or-later（[LICENSE](LICENSE)）。第三者コードの帰属:

- `src/fpga/apf/` と Quartus プロジェクトは Analogue の
  [core-template](https://github.com/open-fpga/core-template) 由来
- `src/fpga/core/data_loader.sv` は agg23 の
  [analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils)（MIT）
- 移植の構成は全体を通じて [PocketCPC](https://github.com/stilvoid/PocketCPC) を参照
