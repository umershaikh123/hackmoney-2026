"use client";

import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { useGetOrder, useGetOrderValue, useCancelOrder } from "@/hooks/use-ghost-vault";
import {
  ORDER_TYPE_LABELS,
  ORDER_STATUS_LABELS,
  OrderStatus,
  USDC,
  WETH,
} from "@/lib/contracts";

function tokenSymbol(address: string): string {
  const lower = address.toLowerCase();
  if (lower === USDC.toLowerCase()) return "USDC";
  if (lower === WETH.toLowerCase()) return "WETH";
  return `${address.slice(0, 6)}...`;
}

function tokenDecimals(address: string): number {
  return address.toLowerCase() === USDC.toLowerCase() ? 6 : 18;
}

const STATUS_VARIANT: Record<number, "default" | "secondary" | "outline"> = {
  [OrderStatus.ACTIVE]: "default",
  [OrderStatus.EXECUTED]: "secondary",
  [OrderStatus.CANCELLED]: "outline",
};

export function OrderCard({ orderId }: { orderId: bigint }) {
  const { address } = useAccount();
  // getOrder returns: [owner, orderType, status, tokenIn, amountIn, vaultShares, intentHash, createdAt, minDelay]
  const { data: order, isLoading: orderLoading } = useGetOrder(orderId);
  // getOrderValue returns: [currentValue, yieldAccrued]
  const { data: value, isLoading: valueLoading } = useGetOrderValue(orderId);
  const { cancelOrder, isPending: cancelling } = useCancelOrder();

  if (orderLoading) {
    return (
      <Card>
        <CardContent className="space-y-3 p-4">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-full" />
          <Skeleton className="h-4 w-16" />
        </CardContent>
      </Card>
    );
  }

  if (!order) return null;

  // getOrder returns a tuple: [owner, orderType, status, tokenIn, amountIn, vaultShares, intentHash, createdAt, minDelay]
  const data = order as readonly [string, number, number, string, bigint, bigint, string, bigint, bigint];
  const owner = data[0];
  const orderTypeNum = Number(data[1]);
  const statusNum = Number(data[2]);
  const tokenIn = data[3];
  const amountIn = data[4];
  const createdAt = data[7];
  const minDelay = data[8];

  // Filter: only show orders belonging to the connected wallet
  if (address && owner.toLowerCase() !== address.toLowerCase()) {
    return null;
  }

  const symbol = tokenSymbol(tokenIn);
  const decimals = tokenDecimals(tokenIn);
  const formattedAmount = formatUnits(amountIn, decimals);
  const isActive = statusNum === OrderStatus.ACTIVE;

  // getOrderValue returns: [currentValue, yieldAccrued]
  const valueData = value as readonly [bigint, bigint] | undefined;
  const currentValue = valueData ? formatUnits(valueData[0], decimals) : "—";
  const yieldAccrued = valueData ? formatUnits(valueData[1], decimals) : "0";

  const createdDate = new Date(Number(createdAt) * 1000);
  const formattedDate = createdAt > 0n
    ? createdDate.toLocaleDateString()
    : "—";

  return (
    <Card className={isActive ? "" : "opacity-50"}>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 p-4 pb-2">
        <CardTitle className="text-sm font-medium">
          Order #{orderId.toString()}
        </CardTitle>
        <div className="flex items-center gap-2">
          <Badge variant="outline">
            {ORDER_TYPE_LABELS[orderTypeNum] ?? "Unknown"}
          </Badge>
          <Badge variant={STATUS_VARIANT[statusNum] ?? "outline"}>
            {ORDER_STATUS_LABELS[statusNum] ?? "Unknown"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-2 p-4 pt-0">
        <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
          <span className="text-muted-foreground">Token</span>
          <span className="text-right font-medium">{symbol}</span>

          <span className="text-muted-foreground">Deposited</span>
          <span className="text-right font-mono">
            {formattedAmount} {symbol}
          </span>

          <span className="text-muted-foreground">Current Value</span>
          <span className="text-right font-mono">
            {valueLoading ? (
              <Skeleton className="ml-auto h-4 w-16" />
            ) : (
              `${currentValue} ${symbol}`
            )}
          </span>

          <span className="text-muted-foreground">Yield Earned</span>
          <span className="text-right font-mono text-green-500">
            +{yieldAccrued} {symbol}
          </span>

          <span className="text-muted-foreground">Created</span>
          <span className="text-right">{formattedDate}</span>

          {minDelay > 0n ? (
            <>
              <span className="text-muted-foreground">Min Delay</span>
              <span className="text-right">
                {Number(minDelay / 60n)}m
              </span>
            </>
          ) : null}
        </div>

        {isActive ? (
          <Button
            variant="destructive"
            size="sm"
            className="mt-2 w-full"
            disabled={cancelling}
            onClick={() => cancelOrder(orderId)}
          >
            {cancelling ? "Cancelling..." : "Cancel Order"}
          </Button>
        ) : null}
      </CardContent>
    </Card>
  );
}
