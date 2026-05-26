import { useState, useEffect, useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { ArrowLeft, RefreshCw, AlertTriangle, CheckCircle, Fingerprint, Copy } from 'lucide-react'
import { NodeUuidInfo, UuidManagerResponse } from '../types'
import api from '../api/client'
import { useGoBack } from '../utils/navigation'

const col = createColumnHelper<NodeUuidInfo>()

type BulkAction = 'update_script' | 'install_scrot' | 'restart_aro' | 'restart_watchdog' | 'reboot_vps' | 'proxy_test'

const BULK_ACTIONS: { id: BulkAction; label: string; cls: string; confirmMsg: (n: number) => string }[] = [
  { id: 'update_script',    label: 'Cập nhật Script',  cls: 'bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300',  confirmMsg: n => `Gửi lệnh cập nhật script đến ${n} node?` },
  { id: 'restart_aro',      label: 'Restart ARO',       cls: 'bg-green-600 hover:bg-green-700 disabled:bg-green-300',     confirmMsg: n => `Gửi lệnh restart ARO đến ${n} node?` },
  { id: 'restart_watchdog', label: 'Restart Watchdog',  cls: 'bg-teal-600 hover:bg-teal-700 disabled:bg-teal-300',       confirmMsg: n => `Gửi lệnh restart Watchdog đến ${n} node?` },
  { id: 'proxy_test',       label: 'Test Proxy',        cls: 'bg-cyan-600 hover:bg-cyan-700 disabled:bg-cyan-300',       confirmMsg: n => `Gửi lệnh test proxy đến ${n} node?` },
  { id: 'install_scrot',    label: 'Cài scrot',         cls: 'bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300', confirmMsg: n => `Gửi lệnh cài scrot đến ${n} node?` },
  { id: 'reboot_vps',       label: 'Reboot VPS',        cls: 'bg-red-700 hover:bg-red-800 disabled:bg-red-400',          confirmMsg: n => `Reboot VPS của ${n} node? Hành động này sẽ khởi động lại máy chủ!` },
]

function timeAgo(iso: string | null): string {
  if (!iso) return '—'
  const secs = Math.floor((Date.now() - new Date(iso + 'Z').getTime()) / 1000)
  if (secs < 60) return `${secs}s ago`
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`
  return `${Math.floor(secs / 86400)}d ago`
}

function StatusBadge({ status, isStale }: { status: string | null; isStale: boolean }) {
  if (isStale) return <span className="px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-500">Stale</span>
  const map: Record<string, string> = {
    Online: 'bg-green-100 text-green-700',
    Offline: 'bg-red-100 text-red-700',
    NoInternet: 'bg-yellow-100 text-yellow-700',
    Unbound: 'bg-purple-100 text-purple-700',
    proxy_expired: 'bg-orange-100 text-orange-700',
  }
  const cls = (status && map[status]) || 'bg-gray-100 text-gray-500'
  return <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${cls}`}>{status || '—'}</span>
}

export default function UuidStats() {
  useEffect(() => { document.title = '🔑 UUID Check | ARO Dashboard' }, [])
  const navigate = useNavigate()
  const goBack = useGoBack()
  const qc = useQueryClient()
  const [onlyDuplicates, setOnlyDuplicates] = useState(false)
  const [sorting, setSorting] = useState<SortingState>([])
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [bulkResult, setBulkResult] = useState<string | null>(null)

  const { data, isLoading, isFetching, refetch } = useQuery<UuidManagerResponse>({
    queryKey: ['uuid-manager', onlyDuplicates],
    queryFn: () => api.get(`/uuid-manager/nodes?only_duplicates=${onlyDuplicates}`).then(r => r.data),
    refetchInterval: 60_000,
  })

  const bulkCmd = useMutation({
    mutationFn: ({ action, node_ids }: { action: string; node_ids: string[] }) =>
      api.post('/commands/bulk', { action, node_ids }),
    onSuccess: (_, vars) => {
      setBulkResult(`Đã gửi lệnh "${vars.action}" đến ${vars.node_ids.length} node`)
      setTimeout(() => setBulkResult(null), 4000)
      setSelected(new Set())
      qc.invalidateQueries({ queryKey: ['uuid-manager'] })
    },
  })

  const nodes = data?.nodes ?? []

  const toggleSelect = (id: string) =>
    setSelected(prev => { const s = new Set(prev); s.has(id) ? s.delete(id) : s.add(id); return s })

  const allIds = useMemo(() => nodes.map(n => n.node_id), [nodes])
  const allSelected = allIds.length > 0 && allIds.every(id => selected.has(id))
  const toggleAll = () => setSelected(allSelected ? new Set() : new Set(allIds))

  const handleBulk = (action: BulkAction) => {
    const ids = [...selected]
    if (!ids.length) return
    const def = BULK_ACTIONS.find(a => a.id === action)!
    if (!window.confirm(def.confirmMsg(ids.length))) return
    bulkCmd.mutate({ action, node_ids: ids })
  }

  const copyUuid = (uuid: string) => navigator.clipboard.writeText(uuid).catch(() => {})

  const columns = useMemo(() => [
    col.display({
      id: 'select',
      header: () => (
        <input type="checkbox" checked={allSelected} onChange={toggleAll}
          className="rounded border-gray-300 text-violet-600 focus:ring-violet-500" />
      ),
      cell: ({ row }) => (
        <input type="checkbox" checked={selected.has(row.original.node_id)}
          onChange={() => toggleSelect(row.original.node_id)}
          className="rounded border-gray-300 text-violet-600 focus:ring-violet-500" />
      ),
      size: 36,
    }),
    col.accessor('node_id', {
      header: 'Node ID',
      cell: ({ getValue }) => (
        <button
          onClick={() => navigate(`/nodes/${encodeURIComponent(getValue())}`)}
          className="font-mono text-xs text-violet-700 hover:underline text-left"
        >
          {getValue()}
        </button>
      ),
    }),
    col.accessor('account', {
      header: 'Account',
      cell: ({ getValue }) => (
        <span className="text-xs text-gray-700">{getValue() || '—'}</span>
      ),
    }),
    col.accessor('uuid', {
      header: 'UUID',
      cell: ({ getValue, row }) => {
        const uuid = getValue()
        if (!uuid) return <span className="text-xs text-gray-400 italic">chưa có</span>
        return (
          <div className="flex items-center gap-1.5">
            {row.original.is_uuid_duplicate && (
              <AlertTriangle size={13} className="text-amber-500 shrink-0" />
            )}
            <span className="font-mono text-xs text-gray-800 break-all">{uuid}</span>
            <button
              onClick={() => copyUuid(uuid)}
              className="text-gray-400 hover:text-gray-600 shrink-0"
              title="Copy UUID"
            >
              <Copy size={12} />
            </button>
          </div>
        )
      },
    }),
    col.accessor('aro_status', {
      header: 'Status',
      cell: ({ getValue, row }) => (
        <StatusBadge status={getValue()} isStale={row.original.is_stale} />
      ),
    }),
    col.accessor('last_seen', {
      header: 'Last Seen',
      cell: ({ getValue }) => (
        <span className="text-xs text-gray-500">{timeAgo(getValue())}</span>
      ),
    }),
  ], [nodes, selected, allSelected])

  const table = useReactTable({
    data: nodes,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  return (
    <div className="min-h-screen bg-gray-50">
      <div className="max-w-7xl mx-auto px-4 py-6">
        {/* Header */}
        <div className="flex items-center gap-3 mb-6">
          <button onClick={goBack} className="p-2 hover:bg-gray-200 rounded-lg transition-colors">
            <ArrowLeft size={18} />
          </button>
          <Fingerprint size={22} className="text-violet-600" />
          <div>
            <h1 className="text-xl font-bold text-gray-900">UUID Check</h1>
            <p className="text-sm text-gray-500">Kiểm tra trùng lặp UUID tài khoản ARO</p>
          </div>
          <div className="ml-auto flex items-center gap-2">
            <button
              onClick={() => refetch()}
              disabled={isFetching}
              className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40 transition-colors"
              title="Refresh"
            >
              <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
            </button>
          </div>
        </div>

        {/* Stats cards */}
        {data && (
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-4 mb-6">
            <div className="bg-white rounded-xl border border-gray-200 p-4">
              <div className="text-2xl font-bold text-gray-900">{data.total}</div>
              <div className="text-sm text-gray-500 mt-0.5">Tổng số node</div>
            </div>
            <div className={`bg-white rounded-xl border p-4 ${data.duplicate_uuid_count > 0 ? 'border-amber-300' : 'border-gray-200'}`}>
              <div className={`text-2xl font-bold ${data.duplicate_uuid_count > 0 ? 'text-amber-600' : 'text-gray-900'}`}>
                {data.duplicate_uuid_count}
              </div>
              <div className="text-sm text-gray-500 mt-0.5">UUID bị trùng</div>
            </div>
            <div className={`bg-white rounded-xl border p-4 ${data.affected_node_count > 0 ? 'border-amber-300' : 'border-gray-200'}`}>
              <div className={`text-2xl font-bold ${data.affected_node_count > 0 ? 'text-amber-600' : 'text-gray-900'}`}>
                {data.affected_node_count}
              </div>
              <div className="text-sm text-gray-500 mt-0.5">Node bị ảnh hưởng</div>
            </div>
          </div>
        )}

        {/* No duplicates banner */}
        {data && data.duplicate_uuid_count === 0 && (
          <div className="flex items-center gap-2 bg-green-50 border border-green-200 rounded-xl px-4 py-3 mb-4 text-green-700 text-sm">
            <CheckCircle size={16} />
            Không phát hiện UUID trùng lặp.
          </div>
        )}

        {/* Duplicate warning banner */}
        {data && data.duplicate_uuid_count > 0 && (
          <div className="flex items-center gap-2 bg-amber-50 border border-amber-200 rounded-xl px-4 py-3 mb-4 text-amber-700 text-sm">
            <AlertTriangle size={16} />
            Phát hiện <strong>{data.duplicate_uuid_count}</strong> UUID trùng trên <strong>{data.affected_node_count}</strong> node. Có thể nhiều node đang dùng cùng một tài khoản.
          </div>
        )}

        {/* Filters + bulk actions */}
        <div className="flex flex-wrap items-center gap-3 mb-4">
          <label className="flex items-center gap-2 text-sm text-gray-700 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={onlyDuplicates}
              onChange={e => { setOnlyDuplicates(e.target.checked); setSelected(new Set()) }}
              className="rounded border-gray-300 text-violet-600 focus:ring-violet-500"
            />
            Chỉ hiện UUID trùng
          </label>

          {selected.size > 0 && (
            <div className="flex flex-wrap items-center gap-2 ml-2">
              <span className="text-sm text-gray-500">{selected.size} node được chọn:</span>
              {BULK_ACTIONS.map(a => (
                <button
                  key={a.id}
                  onClick={() => handleBulk(a.id)}
                  disabled={bulkCmd.isPending}
                  className={`px-3 py-1 rounded text-xs font-medium text-white transition-colors ${a.cls}`}
                >
                  {a.label}
                </button>
              ))}
            </div>
          )}
        </div>

        {bulkResult && (
          <div className="mb-3 px-4 py-2 bg-green-50 border border-green-200 rounded-lg text-sm text-green-700">
            {bulkResult}
          </div>
        )}

        {/* Table */}
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          {isLoading ? (
            <div className="py-12 text-center text-gray-400 text-sm">Đang tải...</div>
          ) : nodes.length === 0 ? (
            <div className="py-12 text-center text-gray-400 text-sm">Không có dữ liệu</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  {table.getHeaderGroups().map(hg => (
                    <tr key={hg.id} className="border-b border-gray-100 bg-gray-50">
                      {hg.headers.map(header => (
                        <th
                          key={header.id}
                          className="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide cursor-pointer select-none whitespace-nowrap"
                          onClick={header.column.getToggleSortingHandler()}
                        >
                          {flexRender(header.column.columnDef.header, header.getContext())}
                          {header.column.getIsSorted() === 'asc' ? ' ↑' : header.column.getIsSorted() === 'desc' ? ' ↓' : ''}
                        </th>
                      ))}
                    </tr>
                  ))}
                </thead>
                <tbody>
                  {table.getRowModel().rows.map(row => {
                    const isDup = row.original.is_uuid_duplicate
                    return (
                      <tr
                        key={row.id}
                        className={`border-b border-gray-50 hover:bg-gray-50 transition-colors border-l-2 ${isDup ? 'bg-amber-50 border-l-amber-400' : 'border-l-transparent'}`}
                      >
                        {row.getVisibleCells().map(cell => (
                          <td key={cell.id} className="px-4 py-3">
                            {flexRender(cell.column.columnDef.cell, cell.getContext())}
                          </td>
                        ))}
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {data && (
          <div className="mt-3 text-xs text-gray-400 text-right">
            {data.total} node · tự động cập nhật sau 60 giây
          </div>
        )}
      </div>
    </div>
  )
}
