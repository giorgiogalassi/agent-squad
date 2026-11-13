#!/usr/bin/env bash
# Scaffold for eval case forge-already-covered (see lib/scaffold-common.sh).
# Builds a small frameworkless TypeScript store inside the fixture repo: leaving
# a section calls resetSection(); entering the catalog loads attribute
# definitions; the product list sorts by a fixed field or by `attr:<id>`.
set -eu
. "$(dirname "$0")/../lib/scaffold-common.sh"
squad_scaffold detached

cd "$PROJECT"
mkdir -p src
cat > src/store.ts <<'EOS'
export type SortKey = 'name' | 'price' | `attr:${string}`;
export type Section = 'catalog' | 'orders';

export interface SectionState {
  sort: SortKey;
  attributeIds: string[];
}

const DEFAULT_SORT: SortKey = 'name';

const state: Record<Section, SectionState> = {
  catalog: { sort: DEFAULT_SORT, attributeIds: [] },
  orders: { sort: DEFAULT_SORT, attributeIds: [] },
};

let current: Section = 'catalog';

export function getState(section: Section): SectionState {
  return state[section];
}

// Leaving a section discards everything it held, the sort included.
export function resetSection(section: Section): void {
  state[section] = { sort: DEFAULT_SORT, attributeIds: [] };
}

export function navigate(to: Section): void {
  resetSection(current);
  current = to;
  if (to === 'catalog') {
    loadAttributeDefinitions();
  }
}

// Runs only when the user enters the catalog section.
export function loadAttributeDefinitions(): void {
  state.catalog.attributeIds = fetchAttributeIds();
}

export function setSort(sort: SortKey): void {
  state[current].sort = sort;
}

declare function fetchAttributeIds(): string[];
EOS
cat > src/product-list.ts <<'EOS'
import { getState } from './store';

export interface Product {
  name: string;
  price: number;
  attrs: Record<string, string>;
}

export function sortedProducts(products: Product[]): Product[] {
  const { sort } = getState('catalog');
  const copy = [...products];
  if (sort.startsWith('attr:')) {
    const id = sort.slice(5);
    return copy.sort((a, b) => (a.attrs[id] ?? '').localeCompare(b.attrs[id] ?? ''));
  }
  return copy.sort((a, b) => (sort === 'price' ? a.price - b.price : a.name.localeCompare(b.name)));
}
EOS
cat > CLAUDE.md <<'EOS'
# Fixture store

Navigation: `navigate()` resets the section being left (`resetSection`), so a
section always starts from its defaults when the user comes back to it.
EOS
git add src CLAUDE.md
git -c user.name=fixture -c user.email=fixture@example.com commit -q -m "Add store fixture"
