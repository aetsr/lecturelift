#!/bin/sh
# DFN3 CPU/latency spike. Usage: spike/run_dfn_spike.sh /path/to/DeepFilterNetPlus
set -eu
DFN=${1:?path to DeepFilterNetPlus checkout (libdf.a built with --features capi)}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"; mkdir -p "$OUT"
clang -O2 -o "$OUT/dfn_bench" "$HERE/dfn_bench.c" "$DFN/target/release/libdf.a" \
  -framework CoreFoundation -framework Security -framework SystemConfiguration -liconv
DE="Guten Morgen. In der heutigen Vorlesung besprechen wir die Fourier-Transformation. Zunächst schauen wir uns ein einfaches Signal an, danach die Faltung im Zeitbereich. Achten Sie bitte auf die Schreibweise der Fachbegriffe."
EN="Good morning. In today's lecture we discuss the Fourier transform. First we look at a simple signal, then at convolution in the time domain. Please pay attention to the spelling of the technical terms."
say -v Anna -o "$OUT/de.aiff" "$DE $DE $DE"
say -v Samantha -o "$OUT/en.aiff" "$EN $EN $EN"
for l in de en; do afconvert -f WAVE -d LEF32@48000 -c 1 "$OUT/$l.aiff" "$OUT/$l.wav"; done
for model in DeepFilterNet3_onnx DeepFilterNet3_ll_onnx; do
  for l in de en; do
    for cfg in "100 -200" "100 -40" "10 -40"; do
      set -- $cfg
      printf '%-24s %s lim=%-3s noise=%-4s ' "$model" "$l" "$1" "$2"
      "$OUT/dfn_bench" "$DFN/models/$model.tar.gz" "$OUT/$l.wav" "$1" "$2" 2>/dev/null
    done
  done
done
