"use client"

import { useEffect, useRef } from "react"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useLogStore, type LogType, formatTxHash } from "@/stores/log-store"

const LOG_COLORS: Record<LogType, string> = {
  info: "text-gray-400",
  success: "text-green-400",
  error: "text-red-400",
  tx: "text-blue-400",
  oracle: "text-yellow-400",
  time: "text-purple-400",
}

const LOG_PREFIXES: Record<LogType, string> = {
  info: "INFO",
  success: "OK",
  error: "ERR",
  tx: "TX",
  oracle: "ORACLE",
  time: "TIME",
}

export function LogsPanel() {
  const { logs, clear } = useLogStore()
  const scrollRef = useRef<HTMLDivElement>(null)

  // Auto-scroll to bottom on new logs
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight
    }
  }, [logs])

  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between pb-2">
        <CardTitle className="text-base">Transaction Logs</CardTitle>
        <Button variant="ghost" size="sm" onClick={clear} className="text-xs">
          Clear
        </Button>
      </CardHeader>
      <CardContent>
        <div
          ref={scrollRef}
          className="h-48 overflow-y-auto rounded bg-black p-3 font-mono text-xs"
        >
          {logs.length === 0 ? (
            <p className="text-muted-foreground">
              Waiting for transactions...
            </p>
          ) : (
            logs.map((log, i) => (
              <div key={i} className="flex gap-2">
                <span className="text-gray-500">{log.timestamp}</span>
                <span className={`font-bold ${LOG_COLORS[log.type]}`}>
                  [{LOG_PREFIXES[log.type]}]
                </span>
                <span className={LOG_COLORS[log.type]}>
                  {log.message}
                  {log.txHash && (
                    <span className="ml-1 text-blue-300">
                      {formatTxHash(log.txHash)}
                    </span>
                  )}
                </span>
              </div>
            ))
          )}
        </div>
      </CardContent>
    </Card>
  )
}
