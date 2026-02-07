type LogLevel = "INFO" | "DECISION" | "EXECUTE" | "SKIP" | "ERROR"

const colors = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  cyan: "\x1b[36m",
  magenta: "\x1b[35m",
}

function timestamp(): string {
  return new Date().toLocaleTimeString("en-US", { hour12: false })
}

function formatData(data?: Record<string, unknown>): string {
  if (!data || Object.keys(data).length === 0) return ""
  const pairs = Object.entries(data)
    .map(([k, v]) => `${k}=${v}`)
    .join(" ")
  return ` ${colors.dim}(${pairs})${colors.reset}`
}

function emit(level: LogLevel, message: string, orderId?: number, data?: Record<string, unknown>) {
  const time = `${colors.dim}${timestamp()}${colors.reset}`
  const orderPrefix = orderId !== undefined ? `[#${orderId}] ` : ""

  let levelStr: string
  switch (level) {
    case "INFO":
      levelStr = `${colors.cyan}INFO${colors.reset}`
      break
    case "DECISION":
      levelStr = `${colors.magenta}DECIDE${colors.reset}`
      break
    case "EXECUTE":
      levelStr = `${colors.green}EXEC${colors.reset}`
      break
    case "SKIP":
      levelStr = `${colors.yellow}SKIP${colors.reset}`
      break
    case "ERROR":
      levelStr = `${colors.red}ERROR${colors.reset}`
      break
  }

  const line = `${time} ${levelStr} ${orderPrefix}${message}${formatData(data)}`

  if (level === "ERROR") {
    console.error(line)
  } else {
    console.log(line)
  }
}

export function info(message: string, data?: Record<string, unknown>) {
  emit("INFO", message, undefined, data)
}

export function decision(orderId: number, message: string, data?: Record<string, unknown>) {
  emit("DECISION", message, orderId, data)
}

export function execute(orderId: number, message: string, data?: Record<string, unknown>) {
  emit("EXECUTE", message, orderId, data)
}

export function skip(orderId: number, message: string, data?: Record<string, unknown>) {
  emit("SKIP", message, orderId, data)
}

export function error(message: string, data?: Record<string, unknown>, orderId?: number) {
  emit("ERROR", message, orderId, data)
}
