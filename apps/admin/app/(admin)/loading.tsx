// React Suspense fallback for any (admin)/* route. Mounts the moment
// a Link is clicked and unmounts when the target page's server
// component finishes rendering. Gives instant click-acknowledged
// feedback so the user never wonders whether they actually hit
// something or whether the click missed.
//
// The Nav from (admin)/layout.tsx stays visible on top — only the
// page-content area below swaps to this fallback during navigation.

export default function Loading() {
  return (
    <>
      <div className="fixed inset-x-0 top-0 z-50 h-0.5 overflow-hidden">
        <div className="h-full w-1/3 animate-[loadingbar_1.1s_ease-in-out_infinite] bg-primary" />
      </div>
      <main className="container py-10">
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <span className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-current border-t-transparent" />
          加载中…
        </div>
      </main>
    </>
  );
}
