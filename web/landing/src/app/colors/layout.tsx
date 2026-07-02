import type { Metadata } from "next";

// A design scratch page for picking shader colors — keep it out of search.
export const metadata: Metadata = {
  title: "Hero shader colors",
  robots: { index: false, follow: false },
};

export default function ColorsLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return children;
}
