import type {
  BaseRecord,
  CreateParams,
  CreateResponse,
  CustomParams,
  CustomResponse,
  DataProvider,
  DeleteOneParams,
  DeleteOneResponse,
  GetListParams,
  GetListResponse,
  GetManyParams,
  GetManyResponse,
  GetOneParams,
  GetOneResponse,
  UpdateParams,
  UpdateResponse,
} from '@refinedev/core';
import { EDGE_API_URL } from '../env';
import { edgeFetch } from './http';
import { routeFor } from './resource-map';

// ─────────────────────────────────────────────────────────────────────────
// Custom Refine v5 dataProvider — points at the EDGE REST API, never at
// Postgres. Verified against the official @refinedev/core@5.0.12 contract
// (https://refine.dev/docs/data/data-provider/):
//   getList   → Promise<{ data, total }>
//   getOne    → Promise<{ data }>
//   create    → Promise<{ data }>
//   update    → Promise<{ data }>
//   deleteOne → Promise<{ data }>
//   getMany   → Promise<{ data }>   (optional)
//   custom    → Promise<{ data }>   (optional)
//   getApiUrl → string
//
// Edge list routes return `{ items: [...] }` (not `{ data, total }`), so we
// normalise via the resource map's `listKey`. Pagination/filtering for the
// PENDING admin endpoints is forwarded as query params (limit/offset/...);
// the existing human-help-requests route honours a `status` filter.
// ─────────────────────────────────────────────────────────────────────────

// Pull a list array out of whatever shape the edge returned.
function extractList<T>(payload: unknown, listKey?: string): { data: T[]; total: number } {
  if (Array.isArray(payload)) {
    return { data: payload as T[], total: payload.length };
  }
  if (payload && typeof payload === 'object') {
    const obj = payload as Record<string, unknown>;
    const key = listKey ?? (Array.isArray(obj.items) ? 'items' : 'data');
    const arr = obj[key];
    if (Array.isArray(arr)) {
      const total =
        typeof obj.total === 'number'
          ? obj.total
          : typeof obj.count === 'number'
            ? obj.count
            : arr.length;
      return { data: arr as T[], total };
    }
  }
  return { data: [], total: 0 };
}

// Flatten Refine filters into edge query params. The PENDING admin endpoints
// are expected to accept simple `field=value` pairs plus limit/offset; we only
// forward `eq`-style filters (the one the existing human-help route uses:
// status=...). Anything richer is left to the endpoint once it exists.
function filtersToQuery(params: GetListParams): Record<string, string | number | undefined> {
  const q: Record<string, string | number | undefined> = {};
  const { pagination, filters } = params;
  const current = pagination?.currentPage ?? 1;
  const pageSize = pagination?.pageSize ?? 50;
  q.limit = pageSize;
  q.offset = (current - 1) * pageSize;
  for (const f of filters ?? []) {
    if ('field' in f && (f.operator === 'eq' || f.operator === undefined)) {
      if (f.value !== undefined && f.value !== null) q[f.field] = String(f.value);
    }
  }
  return q;
}

export const dataProvider: DataProvider = {
  getApiUrl: () => `${EDGE_API_URL}/v1`,

  getList: async <TData extends BaseRecord = BaseRecord>(
    params: GetListParams,
  ): Promise<GetListResponse<TData>> => {
    const route = routeFor(params.resource);
    const payload = await edgeFetch<unknown>({
      method: 'GET',
      path: route.basePath,
      query: filtersToQuery(params),
    });
    const { data, total } = extractList<TData>(payload, route.listKey);
    return { data, total };
  },

  getOne: async <TData extends BaseRecord = BaseRecord>(
    params: GetOneParams,
  ): Promise<GetOneResponse<TData>> => {
    const route = routeFor(params.resource);
    const payload = await edgeFetch<unknown>({
      method: 'GET',
      path: `${route.basePath}/${params.id}`,
    });
    // Edge show routes may return `{ data }`, `{ <singular>: {...} }`, or the
    // bare object. Unwrap the common shapes.
    const obj = payload as Record<string, unknown>;
    const data =
      obj && typeof obj === 'object' && 'data' in obj ? (obj.data as TData) : (payload as TData);
    return { data };
  },

  getMany: async <TData extends BaseRecord = BaseRecord>(
    params: GetManyParams,
  ): Promise<GetManyResponse<TData>> => {
    // No batch edge endpoint; fan out to getOne. Fine for admin volumes.
    const route = routeFor(params.resource);
    const results = await Promise.all(
      params.ids.map(async (id) => {
        const payload = await edgeFetch<unknown>({ method: 'GET', path: `${route.basePath}/${id}` });
        const obj = payload as Record<string, unknown>;
        return (obj && 'data' in obj ? obj.data : payload) as TData;
      }),
    );
    return { data: results };
  },

  // create — POST <basePath> for board resources (e.g. preset_bots). The edge
  // returns `{ data }`; we unwrap it. Resources without a create surface simply
  // never reach this path.
  create: async <TData extends BaseRecord = BaseRecord, TVariables = object>(
    params: CreateParams<TVariables>,
  ): Promise<CreateResponse<TData>> => {
    const route = routeFor(params.resource);
    const payload = await edgeFetch<unknown>({
      method: 'POST',
      path: route.basePath,
      body: params.variables,
    });
    const obj = payload as Record<string, unknown>;
    const data = (obj && 'data' in obj ? obj.data : payload) as TData;
    return { data };
  },

  // update — primary use: permission-request decide (EXISTS) and
  // human-help-request decision (EXISTS). We special-case those so the
  // approval pages can call useUpdate without a bespoke hook.
  update: async <TData extends BaseRecord = BaseRecord, TVariables = object>(
    params: UpdateParams<TVariables>,
  ): Promise<UpdateResponse<TData>> => {
    if (params.resource === 'permission_requests') {
      // EXISTING: POST /v1/permission-requests/:id/decide { decision }
      const payload = await edgeFetch<unknown>({
        method: 'POST',
        path: `permission-requests/${params.id}/decide`,
        body: params.variables, // { decision: 'approve' | 'reject' }
      });
      const obj = payload as Record<string, unknown>;
      return { data: (obj.permissionRequest ?? obj.data ?? obj) as TData };
    }
    if (params.resource === 'human_help_requests') {
      // EXISTING: POST /v1/human-help-requests/:id/decision { decision }
      const payload = await edgeFetch<unknown>({
        method: 'POST',
        path: `human-help-requests/${params.id}/decision`,
        body: params.variables, // { decision: 'accepted' | 'declined' }
      });
      return { data: (payload as Record<string, unknown>) as TData };
    }
    // Generic PATCH for future admin resources.
    const route = routeFor(params.resource);
    const payload = await edgeFetch<unknown>({
      method: 'PATCH',
      path: `${route.basePath}/${params.id}`,
      body: params.variables,
    });
    const obj = payload as Record<string, unknown>;
    return { data: (obj && 'data' in obj ? obj.data : payload) as TData };
  },

  deleteOne: async <TData extends BaseRecord = BaseRecord, TVariables = object>(
    params: DeleteOneParams<TVariables>,
  ): Promise<DeleteOneResponse<TData>> => {
    const route = routeFor(params.resource);
    const payload = await edgeFetch<unknown>({
      method: 'DELETE',
      path: `${route.basePath}/${params.id}`,
    });
    return { data: (payload ?? {}) as TData };
  },

  // custom — the escape hatch the admin-action pages use to POST to the
  // intended (PENDING) admin write endpoints. `url` here is the path relative
  // to /v1 (e.g. 'admin/billing/wallet/grant').
  custom: async <TData = unknown>(params: CustomParams): Promise<CustomResponse<TData>> => {
    const method = (params.method?.toUpperCase() ?? 'GET') as
      | 'GET'
      | 'POST'
      | 'PATCH'
      | 'PUT'
      | 'DELETE';
    const payload = await edgeFetch<unknown>({
      method,
      path: params.url.replace(/^\/+/, '').replace(/^v1\//, ''),
      body: params.payload,
      query: params.query as Record<string, string | number | undefined> | undefined,
    });
    return { data: payload as TData };
  },
};
