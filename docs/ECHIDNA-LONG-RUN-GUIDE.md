# Echidna 24小时 Fuzzing 测试指南

## 概述

本指南介绍如何运行 Echidna 24小时长期 fuzzing 测试，以发现潜在的极端边缘情况和安全漏洞。

---

## 快速开始

### 1. 启动 24 小时测试

```bash
./run-echidna-24h.sh start
```

**输出示例：**
```
🚀 Starting Echidna 24-hour fuzzing test...
Contract: contracts/echidna/GTokenStakingInvariants.sol
Target: GTokenStakingInvariants
Config: echidna-long-run.yaml
Log file: echidna-24h-run.log

⏰ This will run for 24 hours (86400 seconds)
📊 Test limit: 1,000,000 executions

✅ Echidna started successfully!
PID: 12345

Commands:
  ./run-echidna-24h.sh status  - Check running status
  ./run-echidna-24h.sh logs    - Tail logs (live)
  ./run-echidna-24h.sh stop    - Stop fuzzing
```

### 2. 检查运行状态

```bash
./run-echidna-24h.sh status
```

### 3. 查看实时日志

```bash
./run-echidna-24h.sh logs
```

（按 Ctrl+C 退出）

### 4. 查看进度摘要

```bash
./run-echidna-24h.sh progress
```

### 5. 停止测试

```bash
./run-echidna-24h.sh stop
```

---

## 配置详情

### echidna-long-run.yaml

| 参数 | 值 | 说明 |
|------|-----|------|
| `testLimit` | 1,000,000 | 最大测试次数 |
| `timeout` | 86400 | 超时时间（24小时） |
| `workers` | 4 | 并行 worker 数量 |
| `coverage` | true | 启用覆盖率收集 |
| `corpusDir` | "corpus-long" | 语料库保存目录 |
| `shrinkLimit` | 10000 | 发现问题时的收缩尝试次数 |

### 调整配置

**缩短测试时间（6小时）：**
```yaml
testLimit: 250000
timeout: 21600  # 6 hours
```

**延长测试时间（48小时）：**
```yaml
testLimit: 2000000
timeout: 172800  # 48 hours
```

**增加并行度（8 workers）：**
```yaml
workers: 8
```

---

## 监控和诊断

### 方法 1: 使用脚本命令

```bash
# 每隔5分钟检查一次状态
watch -n 300 "./run-echidna-24h.sh progress"
```

### 方法 2: 直接查看日志

```bash
# 查看最后100行日志
tail -100 echidna-24h-run.log

# 搜索失败的测试
grep -i "failed\|error\|revert" echidna-24h-run.log

# 统计测试次数
grep -c "coverage" echidna-24h-run.log
```

### 方法 3: 监控进程资源使用

```bash
# macOS
ps aux | grep echidna

# 查看CPU和内存使用
top -pid $(cat .echidna.pid)
```

---

## 预期输出

### 正常运行示例

```
[2025-10-31 16:22:27] Running slither on `contracts/echidna/GTokenStakingInvariants.sol`... Done!
[2025-10-31 16:22:28] [Worker 0] New coverage: 3288 instr, 3 contracts, 4 seqs in corpus
[2025-10-31 16:22:29] [Worker 1] New coverage: 3306 instr, 3 contracts, 6 seqs in corpus
...
[status] tests: 0/7, fuzzing: 125000/1000000, values: [], cov: 3450, corpus: 42, gas/s: 184560789

echidna_total_staked_equals_balance: passing
echidna_total_shares_equals_total_staked: passing
echidna_user_balance_not_exceed_shares: passing
echidna_available_not_exceed_balance: passing
echidna_locked_not_exceed_balance: passing
echidna_shares_conversion_is_one_to_one: passing
echidna_gtoken_conversion_is_one_to_one: passing
```

### 发现问题时的输出

```
echidna_total_staked_equals_balance: failed!💥
  Call sequence:
    1. stake(1000000000000000000)
    2. requestUnstake()
    3. unstake()

  Counterexample: ...
```

---

## 结果分析

### 24 小时后检查结果

```bash
# 查看最终结果
tail -200 echidna-24h-run.log

# 检查是否有失败的测试
grep -A 10 "failed" echidna-24h-run.log

# 查看最终覆盖率
grep "Unique instructions" echidna-24h-run.log | tail -1
```

### 语料库分析

```bash
# 查看生成的测试用例
ls -la corpus-long/

# 统计语料库大小
echo "Total test cases: $(ls corpus-long/ | wc -l)"
```

### 覆盖率报告

Echidna 会自动生成覆盖率数据：

```bash
# 如果启用了 Slither
ls crytic-export/
```

---

## 性能优化

### 1. 调整 Worker 数量

根据 CPU 核心数调整：

```yaml
# 4核CPU
workers: 4

# 8核CPU
workers: 8

# 16核CPU
workers: 12  # 不要设置超过CPU核心数
```

### 2. Gas 限制优化

```yaml
propMaxGas: 12000000  # 默认
# 如果测试很慢，可以降低：
propMaxGas: 8000000
```

### 3. 收缩限制

```yaml
shrinkLimit: 10000  # 深度收缩（慢但准确）
shrinkLimit: 5000   # 平衡
shrinkLimit: 1000   # 快速（但可能错过最小化的反例）
```

---

## 常见问题

### Q1: Echidna 提前结束了？

**原因**: 可能达到了 testLimit

**解决**:
```yaml
# 增加测试限制
testLimit: 2000000
```

### Q2: CPU 使用率很高？

**正常现象**: Echidna 会使用多个 worker 并行测试

**降低资源使用**:
```yaml
# 减少 worker 数量
workers: 2
```

### Q3: 内存不足？

**解决**:
```yaml
# 限制语料库大小
corpusDir: "corpus-long"
# 定期清理旧的语料库
```

### Q4: 如何在服务器上后台运行？

**使用 screen 或 tmux**:
```bash
# 使用 screen
screen -S echidna-test
./run-echidna-24h.sh start
# Ctrl+A, D 分离

# 重新连接
screen -r echidna-test
```

**或使用 systemd（Linux）**:
```bash
# 创建 systemd service 文件
sudo nano /etc/systemd/system/echidna-fuzzing.service
```

---

## 高级用法

### 1. 使用特定种子（可重现测试）

修改 `echidna-long-run.yaml`:
```yaml
seed: 12345  # 固定种子，每次运行结果相同
```

### 2. 只测试特定属性

创建自定义测试合约：
```solidity
contract CriticalInvariants {
    // 只包含最关键的不变量
    function echidna_total_staked_equals_balance() public view returns (bool) {
        // ...
    }
}
```

### 3. 增量测试

```bash
# 第一次运行（24小时）
./run-echidna-24h.sh start

# 等待完成后，继续运行（使用已有语料库）
# 语料库会保留在 corpus-long/
./run-echidna-24h.sh start  # 会自动加载已有语料库继续测试
```

---

## 最佳实践

### 1. 定期监控

设置 cron job 每小时检查一次：
```bash
# 编辑 crontab
crontab -e

# 添加：
0 * * * * cd /path/to/SuperPaymaster && ./run-echidna-24h.sh progress >> echidna-hourly-check.log 2>&1
```

### 2. 保存结果

```bash
# 测试完成后，保存完整结果
cp echidna-24h-run.log "echidna-results-$(date +%Y%m%d-%H%M%S).log"
tar -czf "corpus-$(date +%Y%m%d-%H%M%S).tar.gz" corpus-long/
```

### 3. 对比多次运行

```bash
# 运行1（种子 123）
sed -i '' 's/# seed: .*/seed: 123/' echidna-long-run.yaml
./run-echidna-24h.sh start

# 运行2（种子 456）
sed -i '' 's/seed: .*/seed: 456/' echidna-long-run.yaml
./run-echidna-24h.sh start
```

---

## 结果解读

### ✅ 全部通过（预期）

```
echidna_total_staked_equals_balance: passing
echidna_total_shares_equals_total_staked: passing
... (7/7 passing)

Unique instructions: 3500+
Total calls: 1000000+
```

**结论**: 合约在 100 万次测试中未发现问题，安全性很高

### ⚠️ 发现问题

```
echidna_some_invariant: failed!💥
  Call sequence: [...]
  Shrunk call sequence: [...]
```

**行动**:
1. 记录完整的调用序列
2. 在 Foundry 中重现问题
3. 修复合约逻辑
4. 重新运行 Echidna

---

## 参考资料

- [Echidna 官方文档](https://github.com/crytic/echidna)
- [Echidna 教程](https://secure-contracts.com/program-analysis/echidna/index.html)
- [属性测试最佳实践](https://github.com/crytic/building-secure-contracts/tree/master/program-analysis/echidna)

---

## 总结

运行 24 小时 Echidna fuzzing 测试的完整流程：

```bash
# 1. 启动测试
./run-echidna-24h.sh start

# 2. 每小时检查一次
./run-echidna-24h.sh status

# 3. 24小时后查看结果
./run-echidna-24h.sh progress

# 4. 保存结果
cp echidna-24h-run.log echidna-final-results.log

# 5. 如果需要停止
./run-echidna-24h.sh stop
```

**祝测试顺利！**
