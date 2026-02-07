"use client";

import { useAccount } from "wagmi";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { OrderCard } from "@/components/order-card";
import { useUserOrders } from "@/hooks/use-ghost-vault";
import { useOrderEvents } from "@/hooks/use-order-events";

export function OrderList() {
  const { isConnected } = useAccount();
  const { orderIds, isLoading } = useUserOrders();

  // Fetch and cache order events (executed/cancelled results)
  useOrderEvents();

  if (!isConnected) {
    return (
      <Card>
        <CardContent className="flex min-h-48 items-center justify-center p-6">
          <p className="text-muted-foreground">
            Connect your wallet to view orders
          </p>
        </CardContent>
      </Card>
    );
  }

  if (isLoading) {
    return (
      <div className="space-y-3">
        {Array.from({ length: 3 }, (_, i) => (
          <Card key={i}>
            <CardContent className="space-y-3 p-4">
              <Skeleton className="h-4 w-24" />
              <Skeleton className="h-4 w-full" />
              <Skeleton className="h-4 w-16" />
            </CardContent>
          </Card>
        ))}
      </div>
    );
  }

  if (orderIds.length === 0) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>My Orders</CardTitle>
          <CardDescription>No orders found</CardDescription>
        </CardHeader>
        <CardContent className="flex min-h-32 items-center justify-center">
          <p className="text-sm text-muted-foreground">
            Commit your first order to get started. Your tokens earn yield while
            waiting.
          </p>
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-3">
      {/* Render newest first */}
      {[...orderIds].reverse().map((id) => (
        <OrderCard key={id.toString()} orderId={id} />
      ))}
    </div>
  );
}
