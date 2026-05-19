import { useMemo, useState, useEffect, useCallback, Fragment } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { ArrowLeft, RefreshCw, GitBranch, List, ChevronDown, ChevronRight, X, Save } from 'lucide-react'
import { AccountStats, AccountHierarchyItem } from '../types'
import api from '../api/client'
import { useGoBack } from '../utils/navigation'

const MASTER = 'nauthnael@gmail.com'
const col = createColumnHelper<AccountStats>()

function Pill({ value, cls }: { value: number; cls: string }) {
  if (value === 0) return <span className="text-gray-300 text-sm">—</span>
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${cls}`}>
      {value}
    </span>
  )
}

function TierBadge({ tier, account }: { tier: number | null; account: string }) {
  if (account === MASTER)
    return <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-bold bg-yellow-100 text-yellow-800 border border-yellow-300">⭐ Master</span>
  if (tier === 1)
    return <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-blue-100 text-blue-700 border border-blue-200">T1</span>
  if (tier === 2)
    return <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-green-100 text-green-700 border border-green-200">T2</span>
  return <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs text-gray-400 border border-gray-200">—</span>
}

function rowBg(tier: number | null, account: string) {
  if (account === MASTER) return 'bg-yellow-50 hover:bg-yellow-100'
  if (tier === 1) return 'bg-blue-50 hover:bg-blue-100'
  if (tier === 2) return 'bg-green-50 hover:bg-green-100'
  return 'hover:bg-gray-50'
}

// --- Hierarchy Editor Modal ---
function HierarchyEditorModal({
  onClose,
  allAccounts,
  hierarchy,
  onSaved,
}: {
  onClose: () => void
  allAccounts: string[]
  hierarchy: AccountHierarchyItem[]
  onSaved: () => void
}) {
  const queryClient = useQueryClient()
  const hierMap = useMemo(() => {
    const m: Record<string, string | null> = {}
    for (const h of hierarchy) m[h.account] = h.parent_account
    return m
  }, [hierarchy])

  const [assignments, setAssignments] = useState<Record<string, string | null>>(() => {
    const init: Record<string, string | null> = {}
    for (const a of allAccounts) init[a] = hierMap[a] ?? null
    return init
  })

  const saveMut = useMutation({
    mutationFn: () =>
      api.put('/accounts/hierarchy', {
        assignments: Object.entries(assignments).map(([account, parent_account]) => ({
          account,
          parent_account,
        })),
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['hierarchy'] })
      queryClient.invalidateQueries({ queryKey: ['accounts'] })
      onSaved()
      onClose()
    },
  })

  function computeTier(account: string): number | null {
    if (account === MASTER) return 0
    const parent = assignments[account]
    if (parent === MASTER) return 1
    const grandparent = parent ? assignments[parent] : null
    if (grandparent === MASTER) return 2
    return null
  }

  const parentOptions = [null, ...allAccounts.filter(a => a !== MASTER)]

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="bg-white rounded-xl shadow-2xl w-full max-w-2xl max-h-[80vh] flex flex-col">
        <div className="flex items-center justify-between px-5 py-4 border-b">
          <div>
            <h2 className="text-base font-bold text-gray-800">Phân cấp tài khoản</h2>
            <p className="text-xs text-gray-400 mt-0.5">Chọn tài khoản cha để xác định tier T1 / T2</p>
          </div>
          <button onClick={onClose} className="p-1 text-gray-400 hover:text-gray-700"><X size={18} /></button>
        </div>

        <div className="overflow-y-auto flex-1 px-4 py-3 space-y-1">
          <div className="flex items-center gap-3 px-2 py-2 rounded bg-yellow-50 border border-yellow-200">
            <span className="flex-1 text-sm font-medium text-gray-800 truncate">{MASTER}</span>
            <TierBadge tier={0} account={MASTER} />
            <span className="text-xs text-gray-400 w-44 text-right">Master — không đổi</span>
          </div>

          {allAccounts.filter(a => a !== MASTER).sort().map(acct => {
            const tier = computeTier(acct)
            return (
              <div key={acct} className="flex items-center gap-3 px-2 py-1.5 rounded hover:bg-gray-50 border border-transparent hover:border-gray-200">
                <span className="flex-1 text-sm text-gray-700 truncate" title={acct}>{acct}</span>
                <TierBadge tier={tier} account={acct} />
                <select
                  value={assignments[acct] ?? ''}
                  onChange={e => setAssignments(prev => ({ ...prev, [acct]: e.target.value || null }))}
                  className="w-44 text-xs border border-gray-200 rounded px-2 py-1 focus:outline-none focus:ring-1 focus:ring-blue-400"
                >
                  <option value="">— Không có cha —</option>
                  {parentOptions.filter(p => p !== null && p !== acct).map(p => (
                    <option key={p!} value={p!}>{p}</option>
                  ))}
                </select>
              </div>
            )
          })}
        </div>

        <div className="flex items-center justify-end gap-3 px-5 py-4 border-t bg-gray-50">
          <button onClick={onClose} className="px-4 py-2 text-sm text-gray-600 hover:text-gray-800">Hủy</button>
          <button
            onClick={() => saveMut.mutate()}
            disabled={saveMut.isPending}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 disabled:opacity-50"
          >
            <Save size={14} />
            {saveMut.isPending ? 'Đang lưu...' : 'Lưu'}
          </button>
        </div>
      </div>
    </div>
  )
}

// --- Tree View ---
function TreeView({ data }: { data: AccountStats[] }) {
  const [expanded, setExpanded] = useState<Set<string>>(new Set())

  const toggle = useCallback((acct: string) => {
    setExpanded(prev => {
      const next = new Set(prev)
      if (next.has(acct)) next.delete(acct)
      else next.add(acct)
      return next
    })
  }, [])

  const byAccount = useMemo(() => {
    const m: Record<string, AccountStats> = {}
    for (const r of data) m[r.account] = r
    return m
  }, [data])

  const master = byAccount[MASTER]
  const t1List = useMemo(() => data.filter(r => r.tier === 1).sort((a, b) => b.total_points - a.total_points), [data])
  const t2ByParent = useMemo(() => {
    const m: Record<string, AccountStats[]> = {}
    for (const r of data) {
      if (r.tier === 2 && r.parent_account) {
        m[r.parent_account] = m[r.parent_account] || []
        m[r.parent_account].push(r)
      }
    }
    return m
  }, [data])
  const unassigned = useMemo(() => data.filter(r => r.tier == null && r.account !== MASTER), [data])

  function AccountRow({ r, indent = 0, isMaster = false }: { r: AccountStats; indent?: number; isMaster?: boolean }) {
    const hasChildren = (t2ByParent[r.account]?.length ?? 0) > 0
    const isExpanded = expanded.has(r.account)
    return (
      <tr
        className={`${rowBg(isMaster ? null : r.tier, r.account)} transition-colors ${hasChildren ? 'cursor-pointer' : ''}`}
        onClick={() => hasChildren && toggle(r.account)}
      >
        <td className="px-3 py-2.5 whitespace-nowrap">
          <div className="flex items-center gap-1" style={{ paddingLeft: indent * 20 }}>
            {hasChildren ? (
              isExpanded
                ? <ChevronDown size={14} className="text-gray-500 flex-shrink-0" />
                : <ChevronRight size={14} className="text-gray-500 flex-shrink-0" />
            ) : indent > 0 ? <span className="w-3.5 flex-shrink-0 text-gray-300 text-xs">└</span> : <span className="w-3.5 flex-shrink-0" />}
            <span className="text-sm font-medium text-gray-800 truncate max-w-[200px]" title={r.account}>{r.account}</span>
          </div>
        </td>
        <td className="px-3 py-2.5"><TierBadge tier={isMaster ? 0 : r.tier} account={r.account} /></td>
        <td className="px-3 py-2.5 text-sm font-mono font-semibold">{r.total}</td>
        <td className="px-3 py-2.5"><Pill value={r.online} cls="bg-green-100 text-green-800" /></td>
        <td className="px-3 py-2.5"><Pill value={r.offline} cls="bg-red-100 text-red-800" /></td>
        <td className="px-3 py-2.5"><Pill value={r.vps_offline} cls="bg-gray-200 text-gray-600" /></td>
        <td className="px-3 py-2.5 text-sm font-mono font-semibold text-blue-700">
          {r.total_points.toLocaleString(undefined, { maximumFractionDigits: 0 })}
        </td>
        <td className="px-3 py-2.5">
          {isMaster && r.ref_points_yesterday > 0 ? (
            <span className="text-xs font-mono text-amber-700 font-semibold">
              +{r.ref_points_yesterday.toLocaleString(undefined, { maximumFractionDigits: 0 })}
            </span>
          ) : <span className="text-gray-300 text-xs">—</span>}
        </td>
        <td className="px-3 py-2.5">
          {r.avg_uptime != null ? (
            <span className={`text-sm font-mono ${r.avg_uptime * 100 >= 95 ? 'text-green-600' : r.avg_uptime * 100 >= 80 ? 'text-yellow-600' : 'text-red-600'}`}>
              {(r.avg_uptime * 100).toFixed(1)}%
            </span>
          ) : <span className="text-gray-300">—</span>}
        </td>
      </tr>
    )
  }

  return (
    <div className="overflow-x-auto rounded-lg shadow">
      <table className="min-w-full bg-white divide-y divide-gray-200">
        <thead className="bg-gray-50">
          <tr>
            {['Account', 'Tier', 'Tổng', 'Online', 'Offline', 'VPS Off', 'Điểm hôm qua', 'Ref pts', 'Uptime TB'].map(h => (
              <th key={h} className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider whitespace-nowrap">{h}</th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {master && <AccountRow r={master} isMaster />}
          {t1List.map(t1 => (
            <Fragment key={t1.account}>
              <AccountRow r={t1} indent={1} />
              {expanded.has(t1.account) && [...(t2ByParent[t1.account] ?? [])].sort((a, b) => b.total_points - a.total_points).map(t2 => (
                <AccountRow key={t2.account} r={t2} indent={2} />
              ))}
            </Fragment>
          ))}
          {unassigned.length > 0 && (
            <tr><td colSpan={9} className="px-3 py-2 text-xs text-gray-400 bg-gray-50 font-medium">Chưa phân cấp ({unassigned.length})</td></tr>
          )}
          {[...unassigned].sort((a, b) => b.total_points - a.total_points).map(r => (
            <AccountRow key={r.account} r={r} />
          ))}
        </tbody>
      </table>
    </div>
  )
}

// --- Main Page ---
export default function AccountStatsPage() {
  useEffect(() => { document.title = '💲 Account Stats | ARO Dashboard' }, [])
  const goBack = useGoBack()
  const [sorting, setSorting] = useState<SortingState>([{ id: 'total_points', desc: true }])
  const [viewMode, setViewMode] = useState<'flat' | 'tree'>('flat')
  const [showEditor, setShowEditor] = useState(false)

  const { data = [], isLoading, refetch, isFetching } = useQuery<AccountStats[]>({
    queryKey: ['accounts'],
    queryFn: () => api.get('/dashboard/accounts').then(r => r.data),
    refetchInterval: 60_000,
  })

  const { data: hierarchy = [] } = useQuery<AccountHierarchyItem[]>({
    queryKey: ['hierarchy'],
    queryFn: () => api.get('/accounts/hierarchy').then(r => r.data),
  })

  const allAccounts = useMemo(() => {
    const fromData = data.map(d => d.account)
    const fromHier = hierarchy.map(h => h.account)
    return [...new Set([...fromData, ...fromHier])].filter(Boolean)
  }, [data, hierarchy])

  const totals = useMemo(() => ({
    total: data.reduce((s, r) => s + r.total, 0),
    online: data.reduce((s, r) => s + r.online, 0),
    offline: data.reduce((s, r) => s + r.offline, 0),
    no_internet: data.reduce((s, r) => s + r.no_internet, 0),
    unbound: data.reduce((s, r) => s + r.unbound, 0),
    proxy_expired: data.reduce((s, r) => s + (r.proxy_expired ?? 0), 0),
    vps_offline: data.reduce((s, r) => s + r.vps_offline, 0),
    total_points: data.reduce((s, r) => s + r.total_points, 0),
    t1_count: data.find(r => r.account === MASTER)?.t1_count ?? 0,
    t2_count: data.find(r => r.account === MASTER)?.t2_count ?? 0,
    ref_points: data.find(r => r.account === MASTER)?.ref_points_yesterday ?? 0,
  }), [data])

  const columns = useMemo(() => [
    col.accessor('account', {
      header: 'Account',
      cell: info => (
        <span className="text-sm font-medium text-gray-800 truncate max-w-[220px] block" title={info.getValue()}>
          {info.getValue()}
        </span>
      ),
    }),
    col.display({
      id: 'tier_badge',
      header: 'Tier',
      enableSorting: false,
      cell: info => <TierBadge tier={info.row.original.tier} account={info.row.original.account} />,
    }),
    col.accessor('parent_account', {
      header: 'T1 Cha',
      enableSorting: false,
      cell: info => {
        const v = info.getValue()
        if (!v) return <span className="text-gray-300 text-xs">—</span>
        const prefix = v.split('@')[0].slice(0, 6)
        return <span className="text-xs text-indigo-600 font-mono" title={v}>{prefix}…</span>
      },
    }),
    col.accessor('total',         { header: 'Tổng',        cell: info => <span className="text-sm font-mono font-semibold">{info.getValue()}</span> }),
    col.accessor('online',        { header: 'Online',      cell: info => <Pill value={info.getValue()} cls="bg-green-100 text-green-800" /> }),
    col.accessor('offline',       { header: 'Offline',     cell: info => <Pill value={info.getValue()} cls="bg-red-100 text-red-800" /> }),
    col.accessor('no_internet',   { header: 'No Internet', cell: info => <Pill value={info.getValue()} cls="bg-yellow-100 text-yellow-800" /> }),
    col.accessor('proxy_expired', { header: 'Proxy Exp.',  cell: info => <Pill value={info.getValue() ?? 0} cls="bg-orange-100 text-orange-800" /> }),
    col.accessor('unbound',       { header: 'Unbound',     cell: info => <Pill value={info.getValue()} cls="bg-purple-100 text-purple-800" /> }),
    col.accessor('vps_offline',   { header: 'VPS Off',     cell: info => <Pill value={info.getValue()} cls="bg-gray-200 text-gray-600" /> }),
    col.accessor('total_points', {
      header: 'Điểm hôm qua',
      cell: info => (
        <span className="text-sm font-mono font-semibold text-blue-700">
          {info.getValue().toLocaleString(undefined, { maximumFractionDigits: 0 })}
        </span>
      ),
    }),
    col.accessor('ref_points_yesterday', {
      header: 'Ref pts',
      cell: info => {
        const v = info.getValue()
        if (!v) return <span className="text-gray-300 text-xs">—</span>
        return <span className="text-xs font-mono font-semibold text-amber-700">+{v.toLocaleString(undefined, { maximumFractionDigits: 0 })}</span>
      },
    }),
    col.accessor('avg_uptime', {
      header: 'Uptime TB',
      cell: info => {
        const v = info.getValue()
        if (v == null) return <span className="text-gray-300">—</span>
        const pct = v * 100
        const cls = pct >= 95 ? 'text-green-600' : pct >= 80 ? 'text-yellow-600' : 'text-red-600'
        return <span className={`text-sm font-mono ${cls}`}>{pct.toFixed(1)}%</span>
      },
    }),
  ], [])

  const table = useReactTable({
    data,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  const hasHierarchy = totals.t1_count > 0 || totals.t2_count > 0

  return (
    <div className="min-h-screen bg-gray-100">
      {showEditor && (
        <HierarchyEditorModal
          onClose={() => setShowEditor(false)}
          allAccounts={allAccounts}
          hierarchy={hierarchy}
          onSaved={() => refetch()}
        />
      )}

      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1880px] mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={goBack} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <div className="flex-1">
            <h1 className="text-lg font-bold text-gray-800">Thống kê theo Account</h1>
            <p className="text-xs text-gray-400">{data.length} accounts · {totals.total} nodes</p>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setShowEditor(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-indigo-600 border border-indigo-200 rounded-lg hover:bg-indigo-50"
            >
              <GitBranch size={14} />
              Phân cấp
            </button>
            <div className="flex items-center border border-gray-200 rounded-lg overflow-hidden">
              <button
                onClick={() => setViewMode('flat')}
                className={`flex items-center gap-1 px-3 py-1.5 text-sm ${viewMode === 'flat' ? 'bg-blue-600 text-white' : 'text-gray-500 hover:bg-gray-50'}`}
              >
                <List size={14} />
                Flat
              </button>
              <button
                onClick={() => setViewMode('tree')}
                className={`flex items-center gap-1 px-3 py-1.5 text-sm ${viewMode === 'tree' ? 'bg-blue-600 text-white' : 'text-gray-500 hover:bg-gray-50'}`}
              >
                <GitBranch size={14} />
                Tree
              </button>
            </div>
            <button
              onClick={() => refetch()}
              disabled={isFetching}
              className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40"
            >
              <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-[1880px] mx-auto px-4 py-5 space-y-4">
        <div className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-8 gap-3">
          {[
            { label: 'Accounts',      value: data.length,          border: 'border-blue-400' },
            { label: 'Tổng node',     value: totals.total,         border: 'border-gray-400' },
            { label: 'Online',        value: totals.online,        border: 'border-green-500' },
            { label: 'Offline',       value: totals.offline,       border: 'border-red-500' },
            { label: 'No Internet',   value: totals.no_internet,   border: 'border-yellow-500' },
            { label: 'Proxy Expired', value: totals.proxy_expired, border: 'border-orange-500' },
            { label: 'Unbound',       value: totals.unbound,       border: 'border-purple-500' },
            { label: 'VPS Offline',   value: totals.vps_offline,   border: 'border-gray-400' },
          ].map(c => (
            <div key={c.label} className={`bg-white rounded-lg shadow p-3 border-l-4 ${c.border}`}>
              <p className="text-xs text-gray-500 uppercase tracking-wide">{c.label}</p>
              <p className="text-2xl font-bold mt-0.5 text-gray-800">{c.value}</p>
            </div>
          ))}
        </div>

        <div className="flex flex-wrap gap-3">
          <div className="bg-white rounded-lg shadow p-3 border-l-4 border-blue-500">
            <p className="text-xs text-gray-500 uppercase tracking-wide">Tổng điểm tất cả</p>
            <p className="text-2xl font-bold mt-0.5 text-blue-700">
              {totals.total_points.toLocaleString(undefined, { maximumFractionDigits: 0 })} pts
            </p>
          </div>
          {hasHierarchy && (
            <>
              <div className="bg-white rounded-lg shadow p-3 border-l-4 border-indigo-400">
                <p className="text-xs text-gray-500 uppercase tracking-wide">T1 Accounts</p>
                <p className="text-2xl font-bold mt-0.5 text-indigo-700">{totals.t1_count}</p>
              </div>
              <div className="bg-white rounded-lg shadow p-3 border-l-4 border-emerald-400">
                <p className="text-xs text-gray-500 uppercase tracking-wide">T2 Accounts</p>
                <p className="text-2xl font-bold mt-0.5 text-emerald-700">{totals.t2_count}</p>
              </div>
              <div className="bg-white rounded-lg shadow p-3 border-l-4 border-amber-400">
                <p className="text-xs text-gray-500 uppercase tracking-wide">Ref pts hôm qua (Master)</p>
                <p className="text-2xl font-bold mt-0.5 text-amber-700">
                  +{totals.ref_points.toLocaleString(undefined, { maximumFractionDigits: 0 })} pts
                </p>
              </div>
            </>
          )}
        </div>

        {isLoading ? (
          <div className="text-center py-16 text-gray-400">Đang tải...</div>
        ) : viewMode === 'tree' ? (
          <TreeView data={data} />
        ) : (
          <div className="overflow-x-auto rounded-lg shadow">
            <table className="min-w-full bg-white divide-y divide-gray-200">
              <thead className="bg-gray-50">
                {table.getHeaderGroups().map(hg => (
                  <tr key={hg.id}>
                    {hg.headers.map(h => (
                      <th
                        key={h.id}
                        onClick={h.column.getToggleSortingHandler()}
                        className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer select-none whitespace-nowrap"
                      >
                        {flexRender(h.column.columnDef.header, h.getContext())}
                        {{ asc: ' ↑', desc: ' ↓' }[h.column.getIsSorted() as string] ?? ''}
                      </th>
                    ))}
                  </tr>
                ))}
              </thead>
              <tbody className="divide-y divide-gray-100">
                {table.getRowModel().rows.map(row => (
                  <tr key={row.id} className={`${rowBg(row.original.tier, row.original.account)} transition-colors`}>
                    {row.getVisibleCells().map(cell => (
                      <td key={cell.id} className="px-3 py-2.5 whitespace-nowrap">
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
            {data.length === 0 && (
              <div className="text-center py-12 text-gray-400">Chưa có dữ liệu</div>
            )}
          </div>
        )}
      </main>
    </div>
  )
}
