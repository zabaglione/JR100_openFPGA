# JR-100 for Analogue Pocket (openFPGA)

松下電器（ナショナル）**JR-100**（1981年）の FPGA 実装を、Analogue Pocket の openFPGA 向けに移植したコアです。

エミュレーション本体は [JR100_MiSTer](https://github.com/zabaglione/JR100_MiSTer) から流用しています。
MiSTer 版は参照エミュレータ [pyjr100emu](https://github.com/zabaglione/pyjr100emu) との命令境界ロックステップで検証済みです。

> **状態: 開発中。** 実装計画と進捗は [docs/PLAN.md](docs/PLAN.md) を参照してください。

## 実装機能（MiSTer 版から引き継ぐもの）

- MB8861H CPU（MC6800 互換 + 独自 5 命令）
- R6522 VIA（サイクル単位）
- 32×24 キャラクタ表示、ユーザー定義グリフ（CGRAM / 共有 VRAM グリフ）
- 実機準拠のビデオタイミング（ドットクロック 7.15909 MHz、NTSC 非準拠の独自同期）
- 表示色の選択（白 / 緑 / アンバー ほか）
- BEEP 音声（帯域制限済み）
- 仮想カセットデッキ（実 ROM の `LOAD` / `SAVE` に対応、600 baud）
- 拡張 RAM 16 KiB（任意）

## Pocket 版で新規に実装するもの

- 仮想キーボード（本体のみで操作可能）
- Dock 経由の USB キーボード
- APF データスロットによるファイル入出力

## ビルド

**GitHub Actions（`build-core` ワークフロー）が主のビルド経路です。** Quartus Prime 18.1.1 Lite を
コンテナで実行し、SD カードにそのまま置ける `build/package/` をアーティファクトとして出力します。

ローカルでも同じスクリプトで合成できますが、Apple Silicon では x86 エミュレーション経由になり
実用的な速度が出ません。最小限の確認用途に留めてください。

```bash
make build          # scripts/build_core.sh（コンテナ実行）
make package        # SD カードのレイアウトを build/package/ に組む
make dist           # 配布 zip を dist/ に作る
```

SD カードへの導入:

```bash
make install POCKET_SD=/Volumes/POCKET
```

Pocket の `Tools > Developer > USB SD Access` を有効にすると、microSD を抜かずに
USB-C 経由でマウントできます。

## ROM について

BASIC ROM は同梱していません。実機から吸い出したものを利用者自身で用意し、
`Assets/jr100/common/boot.rom` として配置してください（char ROM 1 KiB + BASIC ROM 7 KiB の 8 KiB 結合イメージ）。

## ライセンス

GPL-2.0-or-later。詳細と第三者コードの帰属は [LICENSE](LICENSE) を参照してください。
