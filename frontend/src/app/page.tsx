import { Suspense } from "react";
import { Header } from "@/components/header";
import { Dashboard } from "@/components/dashboard";
import { Skeleton } from "@/components/ui/skeleton";

function DashboardFallback() {
  return (
    <div className="mx-auto max-w-2xl space-y-6 px-6 py-8">
      <Skeleton className="mx-auto h-8 w-64" />
      <Skeleton className="mx-auto h-4 w-96" />
      <div className="grid grid-cols-3 gap-4">
        <Skeleton className="h-20 rounded-lg" />
        <Skeleton className="h-20 rounded-lg" />
        <Skeleton className="h-20 rounded-lg" />
      </div>
      <Skeleton className="h-96 rounded-lg" />
    </div>
  );
}

export default function Home() {
  return (
    <div className="min-h-screen bg-background">
      <Header />
      <main>
        <Suspense fallback={<DashboardFallback />}>
          <Dashboard />
        </Suspense>
      </main>
    </div>
  );
}
