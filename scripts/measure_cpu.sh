#!/bin/bash
set -euo pipefail

# 测量 TongYou 进程在流式输出时的平均 CPU 占用。
# 用法：
#   1. 先在 TongYou 里运行：swift scripts/benchmark_rendering.swift
#   2. 立即在另一个 Terminal 里运行：./scripts/measure_cpu.sh

DURATION=${1:-5}

echo "Looking for TongYou process..."
PID=$(pgrep -x "TongYou" | head -n 1 || true)

if [ -z "$PID" ]; then
    echo "Error: TongYou process not found. Make sure the app is running."
    exit 1
fi

echo "Found TongYou PID: $PID"
echo "Sampling CPU for ${DURATION}s..."

TOTAL=0
SAMPLES=0

for ((i=1; i<=DURATION; i++)); do
    # 使用 ps 采样一次 CPU（百分比）
    CPU=$(ps -p "$PID" -o %cpu= | awk '{print $1}' | sed 's/^ *//')
    if [ -z "$CPU" ]; then
        echo "Process disappeared during sampling."
        exit 1
    fi
    printf "  Sample %2d/%d: %s%% CPU\n" "$i" "$DURATION" "$CPU"
    TOTAL=$(awk "BEGIN {print $TOTAL + $CPU}")
    SAMPLES=$((SAMPLES + 1))
    sleep 1
done

AVG=$(awk "BEGIN {printf \"%.1f\", $TOTAL / $SAMPLES}")
echo ""
echo "==============================="
echo "Average CPU over ${SAMPLES}s: ${AVG}%"
echo "==============================="
echo ""
echo "Tip: If 'debug-metrics = true' is enabled, open Window → Resource Stats"
echo "     and check 'Skip' (skipped frames) and 'GPU' (submitted frames)."
