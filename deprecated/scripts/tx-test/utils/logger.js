/**
 * 日志工具 - 提供美化的控制台输出
 */

const colors = {
  reset: "\x1b[0m",
  bright: "\x1b[1m",
  dim: "\x1b[2m",

  // 颜色
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  white: "\x1b[37m",

  // 背景色
  bgRed: "\x1b[41m",
  bgGreen: "\x1b[42m",
  bgYellow: "\x1b[43m",
  bgBlue: "\x1b[44m",
};

class Logger {
  constructor(prefix = "") {
    this.prefix = prefix;
  }

  _format(color, symbol, message) {
    const timestamp = new Date().toISOString().split('T')[1].split('.')[0];
    const prefixStr = this.prefix ? `[${this.prefix}] ` : "";
    return `${colors.dim}${timestamp}${colors.reset} ${color}${symbol}${colors.reset} ${prefixStr}${message}`;
  }

  info(message) {
    console.log(this._format(colors.blue, "ℹ", message));
  }

  success(message) {
    console.log(this._format(colors.green, "✓", message));
  }

  warning(message) {
    console.log(this._format(colors.yellow, "⚠", message));
  }

  error(message) {
    console.error(this._format(colors.red, "✗", message));
  }

  step(stepNumber, totalSteps, message) {
    console.log(this._format(
      colors.cyan,
      `[${stepNumber}/${totalSteps}]`,
      message
    ));
  }

  section(title) {
    console.log("");
    console.log(colors.bright + colors.cyan + "=".repeat(60) + colors.reset);
    console.log(colors.bright + colors.cyan + title + colors.reset);
    console.log(colors.bright + colors.cyan + "=".repeat(60) + colors.reset);
    console.log("");
  }

  subsection(title) {
    console.log("");
    console.log(colors.yellow + "-".repeat(50) + colors.reset);
    console.log(colors.yellow + title + colors.reset);
    console.log(colors.yellow + "-".repeat(50) + colors.reset);
  }

  data(key, value) {
    console.log(`  ${colors.dim}${key}:${colors.reset} ${colors.white}${value}${colors.reset}`);
  }

  address(label, address) {
    console.log(`  ${colors.dim}${label}:${colors.reset} ${colors.magenta}${address}${colors.reset}`);
  }

  amount(label, amount, symbol = "wei") {
    console.log(`  ${colors.dim}${label}:${colors.reset} ${colors.cyan}${amount}${colors.reset} ${symbol}`);
  }

  check(message, passed) {
    const symbol = passed ? "✓" : "✗";
    const color = passed ? colors.green : colors.red;
    console.log(`  ${color}${symbol}${colors.reset} ${message}`);
  }

  divider() {
    console.log(colors.dim + "-".repeat(60) + colors.reset);
  }

  blank() {
    console.log("");
  }

  table(headers, rows) {
    const columnWidths = headers.map((header, i) => {
      const maxRowLength = Math.max(...rows.map(row => String(row[i] || "").length));
      return Math.max(header.length, maxRowLength);
    });

    // Header
    const headerRow = headers.map((header, i) => header.padEnd(columnWidths[i])).join(" | ");
    console.log(colors.bright + headerRow + colors.reset);
    console.log(columnWidths.map(w => "-".repeat(w)).join("-+-"));

    // Rows
    rows.forEach(row => {
      const rowStr = row.map((cell, i) => String(cell || "").padEnd(columnWidths[i])).join(" | ");
      console.log(rowStr);
    });
    console.log("");
  }
}

// 默认导出单例
const logger = new Logger();

module.exports = logger;
module.exports.Logger = Logger;
