import { useMemo, useState, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { ArrowLeft, RefreshCw } from 'lucide-react'
import { AccountStats } from '../types'
import api from '../api/client'
import { useGoBack } from '../utils/navigation'

const col = createColumnHelper<AccountStats>()

function Pill({ value, cls }: { value: number; cls: string }) {
  if (value === 0) return <span className="text-gray-300 text-sm">—</span>
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${cls}`}>
      {value}
    </span>
  )
}

export default function AccountStatsPage() {
  useEffect(() => { document.title = '💲 Account Stats | ARO Dashboard' }, [])
  const navigate = useNavigate()
  const goBack = useGoBack()
  const [sorting, setSorting] = useState<SortingState>([{ id: 'total_points', desc: true }])

  const { data = [], isLoading, refetch, isFetching } = useQuery<AccountStats[]>({
    queryKey: ['accounts'],
    queryFn: () => api.get('/dashboard/accounts').then(r => r.data),
    refetchInterval: 60_000,
  })

  const totals = useMemo(() => ({
    total: data.reduce((s, r) => s + r.total, 0),
    online: data.reduce((s, r) => s + r.online, 0),
    offline: data.reduce((s, r) => s + r.offline, 0),
    no_internet: data.reduce((s, r) => s + r.no_internet, 0),
    unbound: data.reduce((s, r) => s + r.unbound, 0),
    proxy_expired: data.reduce((s, r) => s + (r.proxy_expired ?? 0), 0),
    vps_offline: data.reduce((s, r) => s + r.vps_offline, 0),
    total_points: data.reduce((s, r) => s + r.total_points, 0),
  }), [data])

  const columns = useMemo(() => [
    col.accessor('account', {
      header: 'Account',
      cell: info => (
        <span className="text-sm font-medium text-gray-800 truncate max-w-[220px] block">
          {info.getValue()}
        </span>
      ),
    }),
    col.accessor('total',       { header: 'Tổng', cell: info => <span className="text-sm font-mono font-semibold">{info.getValue()}</span> }),
    col.accessor('online',      { header: 'Online',      cell: info => <Pill value={info.getValue()} cls="bg-green-100 text-green-800" /> }),
    col.accessor('offline',        { header: 'Offline',        cell: info => <Pill value={info.getValue()} cls="bg-red-100 text-red-800" /> }),
    col.accessor('no_internet',    { header: 'No Internet',    cell: info => <Pill value={info.getValue()} cls="bg-yellow-100 text-yellow-800" /> }),
    col.accessor('proxy_expired',  { header: 'Proxy Expired',  cell: info => <Pill value={info.getValue() ?? 0} cls="bg-orange-100 text-orange-800" /> }),
    col.accessor('unbound',        { header: 'Unbound',        cell: info => <Pill value={info.getValue()} cls="bg-purple-100 text-purple-800" /> }),
    col.accessor('vps_offline',    { header: 'VPS Offline',    cell: info => <Pill value={info.getValue()} cls="bg-gray-200 text-gray-600" /> }),
    col.accessor('total_points', {
      header: 'Tổng điểm',
      cell: info => (
        <span className="text-sm font-mono font-semibold text-blue-700">
          {info.getValue().toLocaleString(undefined, { maximumFractionDigits: 0 })}
        </span>
      ),
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

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1880px] mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={goBack} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <div className="flex-1">
            <h1 className="text-lg font-bold text-gray-800">Thống kê theo Account</h1>
            <p className="text-xs text-gray-400">{data.length} accounts · {totals.total} nodes</p>
          </div>
          <button
            onClick={() => refetch()}
            disabled={isFetching}
            className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40"
          >
            <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
          </button>
        </div>
      </header>

      <main className="max-w-[1880px] mx-auto px-4 py-5 space-y-4">
        {/* Summary cards */}
        <div className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-8 gap-3">
          {[
            { label: 'Accounts',       value: data.length,              border: 'border-blue-400' },
            { label: 'Tổng node',      value: totals.total,             border: 'border-gray-400' },
            { label: 'Online',         value: totals.online,            border: 'border-green-500' },
            { label: 'Offline',        value: totals.offline,           border: 'border-red-500' },
            { label: 'No Internet',    value: totals.no_internet,       border: 'border-yellow-500' },
            { label: 'Proxy Expired',  value: totals.proxy_expired,     border: 'border-orange-500' },
            { label: 'Unbound',        value: totals.unbound,           border: 'border-purple-500' },
            { label: 'VPS Offline',    value: totals.vps_offline,       border: 'border-gray-400' },
          ].map(c => (
            <div key={c.label} className={`bg-white rounded-lg shadow p-3 border-l-4 ${c.border}`}>
              <p className="text-xs text-gray-500 uppercase tracking-wide">{c.label}</p>
              <p className="text-2xl font-bold mt-0.5 text-gray-800">{c.value}</p>
            </div>
          ))}
        </div>

        <div className="bg-white rounded-lg shadow p-3 border-l-4 border-blue-500 inline-block">
          <p className="text-xs text-gray-500 uppercase tracking-wide">Tổng điểm tất cả</p>
          <p className="text-2xl font-bold mt-0.5 text-blue-700">
            {totals.total_points.toLocaleString(undefined, { maximumFractionDigits: 0 })} pts
          </p>
        </div>

        {/* Table */}
        {isLoading ? (
          <div className="text-center py-16 text-gray-400">Đang tải...</div>
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
                  <tr key={row.id} className="hover:bg-gray-50 transition-colors">
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
