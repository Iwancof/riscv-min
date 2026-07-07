# RISC-V-min

RV32IMAC CPU の面積最適化実験。Yosys + generic CMOS Liberty で合成面積を測定。

## Current: 2-wide superscalar pipeline, area-optimized (31,826)

`rtl/rv32i_core.sv` — RV32IMAC 完全準拠、2-wide in-order superscalar・3段パイプライン。
元の 81,774 から **38.9%** まで面積を削減（パイプライン・スーパースカラ構造は維持）。

## Area Optimization History

Cell library: `synth/generic_cmos.lib` (NAND2=1.5, DFF=6.0, DFFE=7.5, MUX2=4.0)

| # | Optimization | Area | vs Base | Delta | Description |
|--:|-------------|-----:|--------:|------:|-------------|
| 0 | Baseline | 81,774 | 100.0% | — | 2-wide superscalar, 5-stage, combinational 33×33 MUL |
| 1 | Iterative MUL + DFFE cell | 60,394 | 73.9% | -21,380 | 33×33組合せ乗算器→32cycle shift-add; DFFE (7.5) を liberty に追加 |
| 2 | Iterative shifts | 57,523 | 70.3% | -2,871 | バレルシフタ→1bit/cycle反復; シフトは slot A 専用に |
| 3 | Slot B EXMEM precompute | 57,276 | 70.0% | -247 | exmem_result_b + exmem_pc4_b → 単一 exmem_fwd_b |
| 4 | Bypass-free B + EX RF read | 54,214 | 66.3% | -3,062 | B 側フォワーディング網を除去; RF 読み出しを ID→EX に移動 |
| 5 | B ALU-only + decompress unify | 51,415 | 62.9% | -2,799 | Slot B を LUI/OP-IMM/OP-REG に制限; B 側 decompress() を1回に統合 |
| 6 | Early B WB + held buffer removal | 49,648 | 60.7% | -1,767 | MEMWB_B 削除; held buffer を B→A rotation に置換 |
| 7 | MEMWB removal + compact encoding | 48,867 | 59.8% | -781 | MEMWB_A 削除 (4段化); CF/AMO 制御フィールドを圧縮エンコード |
| 8 | Shared ALU (time-multiplex) | 48,491 | 59.3% | -376 | Slot B ALU 削除; A の ALU を phase 0/1 で時分割共有 |
| 9 | EXMEM payload DFF split | 48,399 | 59.2% | -92 | ペイロードを無条件書き込み→DFF (6.0) に変換 |
| 10 | Shared RF read ports (4→2) | 39,889 | 48.8% | -8,510 | RF mux tree を半減; 読み出しインデックスを ALU phase で時分割 |
| 11 | Single RF write port | 35,027 | 42.8% | -4,862 | B を EX phase-1 の ALU から直接 WB (MEM は必ず bubble で衝突不可能); EXMEM_B 全削除; forwarding を exmem_a 1 ソースに; 死んだ stall/検査を除去 |
| 12 | 3-stage pipeline (IF/ID merge) | 33,594 | 41.1% | -1,433 | fetch+decompress+decode+issue を1段に融合; IFID レジスタ約100bit と rotation 機構を全廃; 分岐ペナルティ 2→1 cycle |
| 13 | B positive-list decode ほか | 33,026 | 40.4% | -568 | B デコーダを許可リスト化 (拒否側のフルデコード網を削除); LR/SC 予約セットを全メモリ粒度に (resv_addr 32bit+比較器削除, 仕様上合法); md_raw_dividend 削除; halt/trap を EX で直接検出 |
| 14 | saved-reg 除去 + AMO 演算器共有 | 32,321 | 39.5% | -705 | exmem_result_a 自体を phase-1 の保持レジスタに転用 (ex_result_a_saved/ex_rs2_a_saved 64bit 削除); AMOADD の加算と MIN/MAX 比較を1本の加減算器に統合; amo_funct5 を 4bit 化 |
| 15 | MEM mux 折り畳み | 32,187 | 39.4% | -134 | AMO/LR/SC は funct3=010 (word) 固定である事実で mem_rd_data_a / dmem_wdata_o / store_strobe の専用脚を汎用 word 経路へ統合 |
| 16 | Slot B 縮約デコンプレッサ | 31,826 | 38.9% | -362 | B が受理する C 形式のみ展開する decompress_b() を新設 (サブセット外は 32'h0 → b_ok で確実に拒否し A で再フェッチ)。PC bit0 除去も試行したが面積悪化のため不採用 |

## Branches

| Branch | Description | Area |
|--------|------------|-----:|
| `main` | 最新の最適化済みスーパースカラ (上記 #16) | 31,826 |
| `rv32imac-pipeline` | 最適化前のスーパースカラ (#0) | 81,774 |
| `rv32imac-pipeline-opt` | 最適化履歴 (main と同期) | 31,826 |
| `rv32imac-area-min` | マルチサイクル FSM (パイプラインなし) | 25,806 |
| `rv32e-minimize` | RV32E マルチサイクル (16 regs, base int only) | 9,125 |

Milestone tags: `area-base` (81,774) / `area-50pct` (39,889) / `area-40pct` (32,321)

#15 以降は delegate-first 体制 (アイデア/仕様/レビュー = Fable、実装 = Codex)。

## Quick start

```bash
make test    # assemble + verilator sim (all programs/*.S)
make synth   # yosys generic CMOS synthesis
make area    # parse area into JSON/Markdown
make report  # test + synth + area
```
