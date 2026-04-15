#!/usr/bin/env bash
set -euo pipefail

# render_validator.sh — 在已经打开的 TongYou 终端里直接运行
# 前置条件：已在 Xcode 或 Terminal 启动 TongYou，且已在 MetalRenderer 中加了日志

echo "========================================"
echo "TongYou DirtyRegion 渲染验证脚本"
echo "========================================"
echo ""
echo "请确保："
echo "1. TongYou 应用正在运行且是前台窗口"
echo "2. 已在 MetalRenderer.swift 加了 print 日志"
echo "3. 下面每个命令执行后，观察日志输出"
echo ""

pause() {
    echo ""
    echo "（按回车继续下一步...）"
    read
}

echo "--- Test 1: 单字符输入（应只 dirty 当前行） ---"
echo "命令：echo -n 'a'"
echo "预期日志：full=false rows=[0]"
pause
echo -n 'a'

pause
echo ""
echo "--- Test 2: 同一行继续输入（仍只 dirty 当前行） ---"
echo "命令：echo -n 'bc'"
echo "预期日志：full=false rows=[0]"
pause
echo -n 'bc'

pause
echo ""
echo "--- Test 3: 光标跳到第5行再输入（dirty row 5） ---"
echo "命令：tput cup 5 0 && echo -n 'x'"
echo "预期日志：full=false rows=[5]"
pause
tput cup 5 0 && echo -n 'x'

pause
echo ""
echo "--- Test 4: 不连续行写入（8, 10, 12） ---"
echo "命令：tput cup 10 0; echo 'line10'; tput cup 12 0; echo 'line12'; tput cup 8 0; echo 'line8'"
echo "预期日志：full=false rows=[8, 10, 12]（顺序可能不同）"
pause
tput cup 10 0 && echo 'line10'
tput cup 12 0 && echo 'line12'
tput cup 8 0 && echo 'line8'

pause
echo ""
echo "--- Test 5: 底部换行触发滚动（full=true） ---"
echo "命令：填满屏幕后按回车，或执行 yes | head -n 50"
echo "预期日志：full=true rows=[]"
pause
yes | head -n 50

pause
echo ""
echo "--- Test 6: clear 清屏（full=true） ---"
echo "命令：clear"
echo "预期日志：full=true rows=[]"
pause
clear

pause
echo ""
echo "--- Test 7: 多行输出（观察是否只 dirty 对应行） ---"
echo "命令：echo -e 'line1\\nline2\\nline3'"
echo "预期日志：full=false rows=[0,1,2] 或连续范围"
pause
echo -e 'line1\nline2\nline3'

pause
echo ""
echo "--- Test 8: vim 进入/退出（alternate screen，应触发 full） ---"
echo "命令：vim +qa"
echo "预期日志：打开 vim 时 full=true，退出时也 full=true"
pause
vim +qa

pause
echo ""
echo "========================================"
echo "验证结束，请把收集到的日志发给我。"
echo "========================================"
